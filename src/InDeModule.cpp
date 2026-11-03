#define MODULE_VERSION_MAJOR     1
#define MODULE_VERSION_MINOR     0
#define MODULE_VERSION_REVISION  1
#define MODULE_VERSION_BUILD     0
#define MODULE_VERSION_LANGUAGE  eng

#include "InDeModule.h"
#include "InDeInterface.h"
#include "InDeProcess.h"
#include "InDeWorker.h"

#ifdef __PCL_WINDOWS
#include <Windows.h>
#else
#include <cstdio>
#include <cstdlib>
#endif

namespace
{

void InDeDiagnostic( const char* message )
{
#ifdef __PCL_WINDOWS
   wchar_t path[32768];
   DWORD length = ::GetEnvironmentVariableW( L"INDE_DIAGNOSTIC_LOG", path, DWORD( sizeof( path )/sizeof( path[0] ) ) );
   if ( length == 0 || length >= sizeof( path )/sizeof( path[0] ) )
      return;
   HANDLE file = ::CreateFileW( path, FILE_APPEND_DATA, FILE_SHARE_READ | FILE_SHARE_WRITE,
                                nullptr, OPEN_ALWAYS, FILE_ATTRIBUTE_NORMAL, nullptr );
   if ( file != INVALID_HANDLE_VALUE )
   {
      DWORD written = 0;
      ::WriteFile( file, message, DWORD( strlen( message ) ), &written, nullptr );
      ::WriteFile( file, "\r\n", 2, &written, nullptr );
      ::CloseHandle( file );
   }
#else
   const char* path = std::getenv( "INDE_DIAGNOSTIC_LOG" );
   if ( path != nullptr && *path != '\0' )
      if ( FILE* file = std::fopen( path, "a" ) )
      {
         std::fprintf( file, "%s\n", message );
         std::fclose( file );
      }
#endif
}

} // namespace

namespace pcl
{

const char* InDeModule::Version() const
{
   return PCL_MODULE_VERSION( MODULE_VERSION_MAJOR,
                              MODULE_VERSION_MINOR,
                              MODULE_VERSION_REVISION,
                              MODULE_VERSION_BUILD,
                              MODULE_VERSION_LANGUAGE );
}

IsoString InDeModule::Name() const
{
   return "InDe";
}

String InDeModule::Description() const
{
   return "InDeConv, InDeStars and InDeNoise native PixInsight processes";
}

String InDeModule::Company() const
{
   return "Local";
}

String InDeModule::Author() const
{
   return "InDe";
}

String InDeModule::Copyright() const
{
   return "Copyright (c) 2026";
}

String InDeModule::TradeMarks() const
{
   return String();
}

String InDeModule::OriginalFileName() const
{
#ifdef __PCL_MACOSX
   return "InDe-pxm.dylib";
#else
   return "InDe-pxm.dll";
#endif
}

void InDeModule::GetReleaseDate( int& year, int& month, int& day ) const
{
   year = 2026;
   month = 10;
   day = 11;
}

void InDeModule::OnUnload()
{
   InDeWorker::Instance().Shutdown();
}

} // pcl

PCL_MODULE_EXPORT int InstallPixInsightModule( int mode )
{
   InDeDiagnostic( "InstallPixInsightModule entered" );
   new pcl::InDeModule;
   InDeDiagnostic( "InDeModule registered" );

   if ( mode == pcl::InstallMode::FullInstall )
   {
      InDeDiagnostic( "FullInstall entered" );
      pcl::InDeProcess* conv = new pcl::InDeProcess( pcl::InDeProduct::Conv );
      InDeDiagnostic( "InDeConv process registered" );
      pcl::InDeProcess* stars = new pcl::InDeProcess( pcl::InDeProduct::Stars );
      InDeDiagnostic( "InDeStars process registered" );
      pcl::InDeProcess* noise = new pcl::InDeProcess( pcl::InDeProduct::Noise );
      InDeDiagnostic( "InDeNoise process registered" );

      new pcl::InDeInterface( pcl::InDeProduct::Conv, conv );
      new pcl::InDeInterface( pcl::InDeProduct::Stars, stars );
      new pcl::InDeInterface( pcl::InDeProduct::Noise, noise );
      InDeDiagnostic( "Interfaces registered" );
   }

   InDeDiagnostic( "InstallPixInsightModule completed" );
   return 0;
}
