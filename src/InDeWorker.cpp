#include "InDeWorker.h"
#include "InDeProcess.h"

#include <pcl/Console.h>
#include <pcl/Exception.h>
#include <pcl/File.h>
#include <pcl/ImageVariant.h>
#include <pcl/ProcessInterface.h>

#ifdef __PCL_WINDOWS
#include <Windows.h>
#else
#include <dlfcn.h>
#include <cstdlib>
#endif

#include <cstring>
#include <string>
#include <vector>

namespace pcl
{

namespace
{

String EnvironmentValue( const char* name )
{
#ifdef __PCL_WINDOWS
   String wideName = String::UTF8ToUTF16( name );
   const wchar_t* widePointer = reinterpret_cast<const wchar_t*>( wideName.c_str() );
   DWORD length = ::GetEnvironmentVariableW( widePointer, nullptr, 0 );
   if ( length == 0 )
      return String();
   std::vector<wchar_t> buffer( length );
   if ( ::GetEnvironmentVariableW( widePointer, buffer.data(), length ) == 0 )
      return String();
   return String( buffer.data() );
#else
   const char* value = std::getenv( name );
   return value != nullptr ? String::UTF8ToUTF16( value ) : String();
#endif
}

String ModuleFilePath()
{
   static int moduleMarker;
#ifdef __PCL_WINDOWS
   HMODULE module = nullptr;
   if ( !::GetModuleHandleExW( GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS |
                               GET_MODULE_HANDLE_EX_FLAG_UNCHANGED_REFCOUNT,
                               reinterpret_cast<LPCWSTR>( &moduleMarker ), &module ) )
      return String();

   std::vector<wchar_t> buffer( 32768 );
   DWORD length = ::GetModuleFileNameW( module, buffer.data(), DWORD( buffer.size() ) );
   if ( length == 0 || length >= buffer.size() )
      return String();
   return File::WindowsPathToUnix( String( buffer.data(), 0, length ) );
#else
   Dl_info info;
   if ( ::dladdr( &moduleMarker, &info ) == 0 || info.dli_fname == nullptr )
      return String();
   return String::UTF8ToUTF16( info.dli_fname );
#endif
}

String PythonRelativePath()
{
#ifdef __PCL_WINDOWS
   return "runtime/python.exe";
#else
   return "runtime/bin/python3";
#endif
}

String ParentDirectory( const String& path )
{
   return File::ExtractDrive( path ) + File::ExtractDirectory( path );
}

String JoinPath( String left, const String& right )
{
   left.Trim();
   while ( left.EndsWith( '/' ) || left.EndsWith( '\\' ) )
      left.Delete( left.Length()-1 );
   return left + '/' + right;
}

bool IsInstallationRoot( const String& root )
{
   return File::Exists( JoinPath( root, PythonRelativePath() ) ) &&
          File::Exists( JoinPath( root, "engine/run_models.py" ) ) &&
          File::Exists( JoinPath( root, "tools/inde_worker.py" ) ) &&
          File::Exists( JoinPath( root, "engine/models/InDeConv.onnx" ) ) &&
          File::Exists( JoinPath( root, "engine/models/InDeNoise.onnx" ) ) &&
          File::Exists( JoinPath( root, "engine/models/InDeStars.onnx" ) );
}

void AppendUInt32LE( ByteArray& data, uint32 value )
{
   data.Add( uint8( value ) );
   data.Add( uint8( value >> 8 ) );
   data.Add( uint8( value >> 16 ) );
   data.Add( uint8( value >> 24 ) );
}

uint32 ReadUInt32LE( const uint8* data )
{
   return uint32( data[0] ) |
          (uint32( data[1] ) << 8) |
          (uint32( data[2] ) << 16) |
          (uint32( data[3] ) << 24);
}

const char* JsonBool( bool value )
{
   return value ? "true" : "false";
}

IsoString JsonNumber( double value )
{
   return IsoString().Format( "%.9g", value );
}

IsoString JsonUnsignedLiteral( uint64 value )
{
   return IsoString().Format( "%llu", static_cast<unsigned long long>( value ) );
}

uint64 JsonUnsigned( const std::string& json, const char* key )
{
   std::string token = std::string( "\"" ) + key + "\":";
   size_t position = json.find( token );
   if ( position == std::string::npos )
      throw Error( String( "InDe response is missing " ) + key + '.' );
   position += token.size();
   while ( position < json.size() && json[position] == ' ' )
      ++position;
   size_t end = position;
   while ( end < json.size() && json[end] >= '0' && json[end] <= '9' )
      ++end;
   if ( end == position )
      throw Error( String( "InDe response has an invalid " ) + key + '.' );
   return std::stoull( json.substr( position, end-position ) );
}

String JsonStringValue( const std::string& json, const char* key )
{
   std::string token = std::string( "\"" ) + key + "\":";
   size_t position = json.find( token );
   if ( position == std::string::npos )
      return String();
   position += token.size();
   while ( position < json.size() && json[position] == ' ' )
      ++position;
   if ( position >= json.size() || json[position] != '"' )
      return String();
   ++position;

   std::string value;
   for ( ; position < json.size(); ++position )
   {
      char c = json[position];
      if ( c == '"' )
         break;
      if ( c == '\\' && position + 1 < json.size() )
      {
         c = json[++position];
         switch ( c )
         {
         case 'n': value += '\n'; break;
         case 'r': value += '\r'; break;
         case 't': value += '\t'; break;
         case '\\': value += '\\'; break;
         case '"': value += '"'; break;
         default: value += c; break;
         }
      }
      else
         value += c;
   }
   return String::UTF8ToUTF16( value.c_str() );
}

} // namespace

IsoString InDeWorker::BuildRequestJson( const Image& image, const InDeInstance& instance ) const
{
   IsoString json;
   json << "{\"command\":\"process\",\"product\":\""
        << InDeProductWorkerId( instance.m_product )
        << "\",\"width\":" << JsonUnsignedLiteral( image.Width() )
        << ",\"height\":" << JsonUnsignedLiteral( image.Height() )
        << ",\"channels\":" << JsonUnsignedLiteral( image.NumberOfNominalChannels() )
        << ",\"payloadBytes\":"
        << JsonUnsignedLiteral( uint64( image.NumberOfPixels() )*
                                image.NumberOfNominalChannels()*sizeof( float ) )
        << ",\"params\":{";

   const char* device = instance.p_device == InDeDeviceParameter::DirectML ? "dml" :
                        instance.p_device == InDeDeviceParameter::CoreML ? "coreml" :
                        instance.p_device == InDeDeviceParameter::CPU ? "cpu" : "auto";
   json << "\"device\":\"" << device << "\",\"overlap\":" << JsonNumber( instance.p_overlap );

   if ( instance.m_product == InDeProduct::Conv )
   {
      json << ",\"ss\":" << JsonNumber( instance.p_ss )
           << ",\"ash\":" << JsonNumber( instance.p_ash )
           << ",\"ansp\":" << JsonBool( instance.p_ansp )
           << ",\"nsd\":" << JsonNumber( instance.p_nsd )
           << ",\"sn\":" << JsonNumber( instance.p_sn )
           << ",\"correctOnly\":" << JsonBool( instance.p_correctOnly )
           << ",\"lunarPlanetary\":" << JsonBool( instance.p_lunarPlanetary );
   }
   else if ( instance.m_product == InDeProduct::Stars )
   {
      json << ",\"stars\":" << JsonBool( instance.p_stars )
           << ",\"unscreen\":" << JsonBool( instance.p_unscreen );
   }
   else
   {
      json << ",\"dn\":" << JsonNumber( instance.p_dn )
           << ",\"iterations\":" << JsonUnsignedLiteral( instance.p_iterations )
           << ",\"csep\":" << JsonBool( instance.p_csep )
           << ",\"fsep\":" << JsonBool( instance.p_fsep )
           << ",\"di\":" << JsonNumber( instance.p_di )
           << ",\"dc\":" << JsonNumber( instance.p_dc )
           << ",\"dhf\":" << JsonNumber( instance.p_dhf )
           << ",\"dlf\":" << JsonNumber( instance.p_dlf )
           << ",\"dihf\":" << JsonNumber( instance.p_dihf )
           << ",\"dilf\":" << JsonNumber( instance.p_dilf )
           << ",\"dchf\":" << JsonNumber( instance.p_dchf )
           << ",\"dclf\":" << JsonNumber( instance.p_dclf )
           << ",\"fs\":" << JsonNumber( instance.p_fs );
   }
   json << "}}";
   while ( (json.Length() & 3) != 0 )
      json.Append( ' ' );
   return json;
}

InDeWorker& InDeWorker::Instance()
{
   static InDeWorker worker;
   return worker;
}

InDeWorker::~InDeWorker()
{
   Shutdown();
}

String InDeWorker::FindInstallationRoot() const
{
   Array<String> candidates;
   String configured = EnvironmentValue( "INDE_INSTALL_DIR" );
   if ( !configured.IsEmpty() )
      candidates << File::WindowsPathToUnix( configured );

   String modulePath = ModuleFilePath();
   if ( !modulePath.IsEmpty() )
   {
      String moduleDirectory = ParentDirectory( modulePath );
      candidates << JoinPath( moduleDirectory, "InDeBackend" );
      candidates << moduleDirectory;
   }

#ifdef __PCL_WINDOWS
   String localAppData = EnvironmentValue( "LOCALAPPDATA" );
   if ( !localAppData.IsEmpty() )
      candidates << JoinPath( File::WindowsPathToUnix( localAppData ), L"Programs/InDe/InDeBackend" );
#else
   String userHome = EnvironmentValue( "HOME" );
   if ( !userHome.IsEmpty() )
      candidates << JoinPath( userHome, "Library/Application Support/InDe/InDeBackend" );
#endif

   for ( const String& candidate : candidates )
   {
      String directory = candidate;
      for ( int level = 0; level < 8 && !directory.IsEmpty(); ++level )
      {
         if ( IsInstallationRoot( directory ) )
            return File::FullPath( directory );
         String parent = ParentDirectory( directory );
         if ( parent == directory )
            break;
         directory = parent;
      }
   }

   throw Error( "InDe cannot locate the installation directory. Set INDE_INSTALL_DIR or reinstall the application." );
}

void InDeWorker::EnsureStarted()
{
   std::lock_guard<std::mutex> lock( m_processMutex );
   if ( m_process && m_process->IsRunning() )
      return;

   m_process.reset();
   String root = FindInstallationRoot();
   String python = JoinPath( root, PythonRelativePath() );
   String worker = JoinPath( root, "tools/inde_worker.py" );
   String engine = JoinPath( root, "engine" );

   m_process = std::make_unique<ExternalProcess>();
   StringList arguments;
   arguments << "-I" << "-B" << "-X" << "utf8" << worker << "--engine-dir" << engine;
   m_process->Start( python, arguments );
   if ( !m_process->WaitForStarted( 30000 ) )
   {
      m_process.reset();
      throw Error( "InDe inference process startup timed out." );
   }
}

void InDeWorker::CheckCancellation( uint64 requestId )
{
   if ( m_generation.load() != requestId )
      throw ProcessAborted();
   if ( Console().AbortRequested() )
   {
      Abort();
      throw ProcessAborted();
   }
}

void InDeWorker::DrainOutput( ByteArray& output, ByteArray& errors )
{
   std::lock_guard<std::mutex> lock( m_processMutex );
   if ( m_process )
   {
      output.Append( m_process->StandardOutput() );
      errors.Append( m_process->StandardError() );
   }
}

void InDeWorker::Process( Image& image, const InDeInstance& instance, Image* starsOutput )
{
   std::lock_guard<std::mutex> requestLock( m_requestMutex );
   uint64 requestId = m_generation.load();
   {
      std::lock_guard<std::mutex> lock( m_processMutex );
      m_requestActive = true;
   }
   try
   {
      CheckCancellation( requestId );
      EnsureStarted();
      CheckCancellation( requestId );

   IsoString json = BuildRequestJson( image, instance );
   ByteArray header;
   static const uint8 magic[] = { 'I', 'D', 'E', '1' };
   header.Append( magic, magic + 4 );
   AppendUInt32LE( header, uint32( json.Length() ) );
   header.Append( reinterpret_cast<const uint8*>( json.Begin() ),
                  reinterpret_cast<const uint8*>( json.End() ) );

   {
      std::lock_guard<std::mutex> lock( m_processMutex );
      if ( !m_process || !m_process->IsRunning() )
         throw Error( "InDe inference process is unavailable." );
      m_process->Write( header );
      size_type count = image.NumberOfPixels();
      for ( int channel = 0; channel < image.NumberOfNominalChannels(); ++channel )
         m_process->Write( image.PixelData( channel ), count*sizeof( float ) );
   }

   for ( ;; )
   {
      CheckCancellation( requestId );
      bool complete = false;
      bool running = false;
      {
         std::lock_guard<std::mutex> lock( m_processMutex );
         if ( m_process )
         {
            complete = m_process->BytesToWrite() == 0;
            running = m_process->IsRunning();
            if ( running && !complete )
               m_process->WaitForDataWritten( 50 );
         }
      }
      if ( complete )
         break;
      if ( !running )
         throw Error( "InDe inference process stopped while receiving image data." );
      ProcessInterface::ProcessEvents();
   }

   ByteArray output;
   ByteArray errors;
   uint32 headerSize = 0;
   uint64 expectedSize = 0;
   for ( ;; )
   {
      CheckCancellation( requestId );
      DrainOutput( output, errors );

      if ( headerSize == 0 && output.Length() >= 8 )
      {
         if ( std::memcmp( output.Begin(), "IDR1", 4 ) != 0 )
            throw Error( "InDe received an invalid inference response." );
         headerSize = ReadUInt32LE( output.Begin() + 4 );
         if ( headerSize == 0 || headerSize > 1024*1024 )
            throw Error( "InDe received an invalid response header size." );
      }

      if ( headerSize != 0 && output.Length() >= size_type( 8 + headerSize ) && expectedSize == 0 )
      {
         std::string responseJson( reinterpret_cast<const char*>( output.Begin() + 8 ), headerSize );
         expectedSize = uint64( 8 ) + headerSize + JsonUnsigned( responseJson, "payloadBytes" );
      }

      if ( expectedSize != 0 && uint64( output.Length() ) >= expectedSize )
         break;

      bool running = false;
      {
         std::lock_guard<std::mutex> lock( m_processMutex );
         if ( m_process )
         {
            running = m_process->IsRunning();
            if ( running )
               m_process->WaitForDataAvailable( 50 );
         }
      }
      if ( !running )
      {
         CheckCancellation( requestId );
         String diagnostics;
         if ( !errors.IsEmpty() )
            diagnostics = String::UTF8ToUTF16( reinterpret_cast<const char*>( errors.Begin() ), 0, errors.Length() );
         throw Error( "InDe inference process ended unexpectedly." +
                      (diagnostics.IsEmpty() ? String() : String( "\n\n" ) + diagnostics) );
      }
      ProcessInterface::ProcessEvents();
   }

   std::string responseJson( reinterpret_cast<const char*>( output.Begin() + 8 ), headerSize );
   if ( responseJson.find( "\"ok\":true" ) == std::string::npos )
   {
      String message = JsonStringValue( responseJson, "error" );
      throw Error( message.IsEmpty() ? "InDe inference failed." : message );
   }

   uint64 width = JsonUnsigned( responseJson, "width" );
   uint64 height = JsonUnsigned( responseJson, "height" );
   if ( width != uint64( image.Width() ) || height != uint64( image.Height() ) )
      throw Error( "InDe response dimensions do not match the input image." );

   size_type count = image.NumberOfPixels();
   int channels = image.NumberOfNominalChannels();
   uint64 bytesPerImage = uint64( count )*channels*sizeof( float );
   uint64 payloadBytes = JsonUnsigned( responseJson, "payloadBytes" );
   bool hasStars = responseJson.find( "\"name\":\"stars\"" ) != std::string::npos;
   uint64 requiredBytes = bytesPerImage*(hasStars ? 2 : 1);
   if ( payloadBytes != requiredBytes || expectedSize != uint64( 8 ) + headerSize + requiredBytes )
      throw Error( "InDe response payload size is inconsistent." );

   const uint8* payload = output.Begin() + 8 + headerSize;
   for ( int channel = 0; channel < channels; ++channel )
      std::memcpy( image.PixelData( channel ),
                   payload + uint64( channel )*count*sizeof( float ),
                   count*sizeof( float ) );

      if ( starsOutput != nullptr )
      {
         if ( hasStars )
         {
            starsOutput->AllocateData( image.Width(), image.Height(), channels, image.ColorSpace() );
            const uint8* stars = payload + bytesPerImage;
            for ( int channel = 0; channel < channels; ++channel )
               std::memcpy( starsOutput->PixelData( channel ),
                            stars + uint64( channel )*count*sizeof( float ),
                            count*sizeof( float ) );
         }
         else
            starsOutput->FreeData();
      }

      {
         std::lock_guard<std::mutex> lock( m_processMutex );
         m_requestActive = false;
      }
   }
   catch ( const ProcessAborted& )
   {
      std::lock_guard<std::mutex> lock( m_processMutex );
      m_requestActive = false;
      throw;
   }
   catch ( ... )
   {
      {
         std::lock_guard<std::mutex> lock( m_processMutex );
         m_requestActive = false;
      }
      ++m_generation;
      StopProcess( true );
      throw;
   }
}

void InDeWorker::Abort()
{
   ++m_generation;
   std::lock_guard<std::mutex> lock( m_processMutex );
   if ( m_requestActive && m_process && m_process->IsRunning() )
      m_process->Kill();
}

void InDeWorker::StopProcess( bool force )
{
   std::lock_guard<std::mutex> lock( m_processMutex );
   if ( m_process && m_process->IsRunning() )
   {
      if ( force )
         m_process->Kill();
      else
         m_process->Terminate();
   }
   m_process.reset();
   m_requestActive = false;
}

void InDeWorker::Shutdown()
{
   ++m_generation;
   StopProcess( true );
}

} // pcl
