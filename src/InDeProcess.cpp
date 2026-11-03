#include "InDeProcess.h"
#include "InDeInterface.h"
#include "InDeWorker.h"

#include <pcl/AutoViewLock.h>
#include <pcl/Console.h>
#include <pcl/ImageVariant.h>
#include <pcl/ImageWindow.h>
#include <pcl/View.h>

namespace pcl
{

InDeProcess* TheInDeConvProcess = nullptr;
InDeProcess* TheInDeStarsProcess = nullptr;
InDeProcess* TheInDeNoiseProcess = nullptr;

IsoString InDeProductProcessId( InDeProduct product )
{
   switch ( product )
   {
   case InDeProduct::Conv:  return "InDeConv";
   case InDeProduct::Stars: return "InDeStars";
   default:                 return "InDeNoise";
   }
}

String InDeProductTitle( InDeProduct product )
{
   switch ( product )
   {
   case InDeProduct::Conv:  return "InDeConv";
   case InDeProduct::Stars: return "InDeStars";
   default:                 return "InDeNoise";
   }
}

IsoString InDeProductWorkerId( InDeProduct product )
{
   switch ( product )
   {
   case InDeProduct::Conv:  return "conv";
   case InDeProduct::Stars: return "stars";
   default:                 return "noise";
   }
}

InDeRealParameter::InDeRealParameter( MetaProcess* process, const IsoString& id,
                                       double minimum, double maximum, double defaultValue,
                                       int precision )
   : MetaDouble( process )
   , m_id( id )
   , m_minimum( minimum )
   , m_maximum( maximum )
   , m_default( defaultValue )
   , m_precision( precision )
{
}

IsoString InDeRealParameter::Id() const { return m_id; }
int InDeRealParameter::Precision() const { return m_precision; }
double InDeRealParameter::MinimumValue() const { return m_minimum; }
double InDeRealParameter::MaximumValue() const { return m_maximum; }
double InDeRealParameter::DefaultValue() const { return m_default; }

InDeUIntParameter::InDeUIntParameter( MetaProcess* process, const IsoString& id,
                                       uint32 minimum, uint32 maximum, uint32 defaultValue )
   : MetaUInt32( process )
   , m_id( id )
   , m_minimum( minimum )
   , m_maximum( maximum )
   , m_default( defaultValue )
{
}

IsoString InDeUIntParameter::Id() const { return m_id; }
double InDeUIntParameter::MinimumValue() const { return m_minimum; }
double InDeUIntParameter::MaximumValue() const { return m_maximum; }
double InDeUIntParameter::DefaultValue() const { return m_default; }

InDeBoolParameter::InDeBoolParameter( MetaProcess* process, const IsoString& id, bool defaultValue )
   : MetaBoolean( process )
   , m_id( id )
   , m_default( defaultValue )
{
}

IsoString InDeBoolParameter::Id() const { return m_id; }
bool InDeBoolParameter::DefaultValue() const { return m_default; }

InDeDeviceParameter::InDeDeviceParameter( MetaProcess* process )
   : MetaEnumeration( process )
{
}

IsoString InDeDeviceParameter::Id() const { return "device"; }
size_type InDeDeviceParameter::NumberOfElements() const { return NumberOfItems; }

IsoString InDeDeviceParameter::ElementId( size_type index ) const
{
   switch ( index )
   {
   case Auto:     return "Auto";
   case DirectML: return "DirectML";
   case CoreML:   return "CoreML";
   default:       return "CPU";
   }
}

int InDeDeviceParameter::ElementValue( size_type index ) const
{
   return int( index );
}

size_type InDeDeviceParameter::DefaultValueIndex() const
{
   return Default;
}

InDeParameterSet::InDeParameterSet( MetaProcess* process, InDeProduct product )
{
   device = new InDeDeviceParameter( process );
   overlap = new InDeRealParameter( process, "overlap", 0, 0.5, 0.2, 2 );

   if ( product == InDeProduct::Conv )
   {
      ss = new InDeRealParameter( process, "sharpenStars", 0, 0.7, 0.5, 2 );
      ash = new InDeRealParameter( process, "adjustStarHalos", -0.5, 0.5, 0, 2 );
      ansp = new InDeBoolParameter( process, "automaticPSF", true );
      nsd = new InDeRealParameter( process, "psfDiameter", 0, 8, 0, 1 );
      sn = new InDeRealParameter( process, "sharpenNonstellar", 0, 1, 0.5, 2 );
      correctOnly = new InDeBoolParameter( process, "correctOnly", false );
      lunarPlanetary = new InDeBoolParameter( process, "lunarPlanetary", false );
   }
   else if ( product == InDeProduct::Stars )
   {
      stars = new InDeBoolParameter( process, "generateStars", false );
      unscreen = new InDeBoolParameter( process, "unscreenStars", false );
   }
   else
   {
      dn = new InDeRealParameter( process, "denoise", 0, 1, 0.9, 2 );
      iterations = new InDeUIntParameter( process, "iterations", 1, 5, 2 );
      csep = new InDeBoolParameter( process, "intensityColorSeparation", false );
      fsep = new InDeBoolParameter( process, "frequencySeparation", false );
      di = new InDeRealParameter( process, "denoiseIntensity", 0, 1, 0.9, 2 );
      dc = new InDeRealParameter( process, "denoiseColor", 0, 1, 0.9, 2 );
      dhf = new InDeRealParameter( process, "denoiseHF", 0, 1, 0.9, 2 );
      dlf = new InDeRealParameter( process, "denoiseLF", 0, 1, 0.9, 2 );
      dihf = new InDeRealParameter( process, "denoiseHFIntensity", 0, 1, 0.9, 2 );
      dilf = new InDeRealParameter( process, "denoiseLFIntensity", 0, 1, 0.9, 2 );
      dchf = new InDeRealParameter( process, "denoiseHFColor", 0, 1, 0.9, 2 );
      dclf = new InDeRealParameter( process, "denoiseLFColor", 0, 1, 0.9, 2 );
      fs = new InDeRealParameter( process, "frequencyScale", 1, 100, 5, 1 );
   }
}

InDeProcess::InDeProcess( InDeProduct product )
   : m_product( product )
   , m_parameters( this, product )
{
   switch ( product )
   {
   case InDeProduct::Conv:  TheInDeConvProcess = this; break;
   case InDeProduct::Stars: TheInDeStarsProcess = this; break;
   case InDeProduct::Noise: TheInDeNoiseProcess = this; break;
   }
}

IsoString InDeProcess::Id() const { return InDeProductProcessId( m_product ); }
IsoString InDeProcess::Category() const { return "InDe"; }
uint32 InDeProcess::Version() const { return 0x100; }

String InDeProcess::Description() const
{
   return InDeProductTitle( m_product ) + " local ONNX image processing";
}

ProcessInterface* InDeProcess::DefaultInterface() const
{
   switch ( m_product )
   {
   case InDeProduct::Conv:  return TheInDeConvInterface;
   case InDeProduct::Stars: return TheInDeStarsInterface;
   default:                 return TheInDeNoiseInterface;
   }
}

ProcessImplementation* InDeProcess::Create() const
{
   return new InDeInstance( this );
}

ProcessImplementation* InDeProcess::Clone( const ProcessImplementation& implementation ) const
{
   const InDeInstance* instance = dynamic_cast<const InDeInstance*>( &implementation );
   return instance != nullptr && instance->Product() == m_product ? new InDeInstance( *instance ) : nullptr;
}

bool InDeProcess::NeedsValidation() const
{
   return false;
}

InDeInstance::InDeInstance( const InDeProcess* process )
   : ProcessImplementation( process )
   , m_product( process->Product() )
{
}

InDeInstance::InDeInstance( const InDeInstance& source )
   : ProcessImplementation( source )
   , m_product( source.m_product )
{
   Assign( source );
}

void InDeInstance::Assign( const ProcessImplementation& implementation )
{
   const InDeInstance* source = dynamic_cast<const InDeInstance*>( &implementation );
   if ( source == nullptr || source->m_product != m_product )
      return;

   p_device = source->p_device;
   p_overlap = source->p_overlap;
   p_ss = source->p_ss;
   p_ash = source->p_ash;
   p_ansp = source->p_ansp;
   p_nsd = source->p_nsd;
   p_sn = source->p_sn;
   p_correctOnly = source->p_correctOnly;
   p_lunarPlanetary = source->p_lunarPlanetary;
   p_stars = source->p_stars;
   p_unscreen = source->p_unscreen;
   p_dn = source->p_dn;
   p_iterations = source->p_iterations;
   p_csep = source->p_csep;
   p_fsep = source->p_fsep;
   p_di = source->p_di;
   p_dc = source->p_dc;
   p_dhf = source->p_dhf;
   p_dlf = source->p_dlf;
   p_dihf = source->p_dihf;
   p_dilf = source->p_dilf;
   p_dchf = source->p_dchf;
   p_dclf = source->p_dclf;
   p_fs = source->p_fs;
   NormalizeParameters();
}

UndoFlags InDeInstance::UndoMode( const View& ) const
{
   return UndoFlag::PixelData;
}

bool InDeInstance::CanExecuteOn( const View& view, String& whyNot ) const
{
   ImageVariant image = view.Image();
   if ( image.IsComplexSample() )
   {
      whyNot = InDeProductTitle( m_product ) + " does not support complex images.";
      return false;
   }
   int channels = image.NumberOfNominalChannels();
   if ( channels != 1 && channels != 3 )
   {
      whyNot = InDeProductTitle( m_product ) + " requires a grayscale or RGB image.";
      return false;
   }
   return true;
}

void InDeInstance::NormalizeParameters()
{
   if ( p_correctOnly )
      p_lunarPlanetary = false;
   if ( !p_stars )
      p_unscreen = false;
}

const InDeProcess* InDeInstance::ProcessMeta() const
{
   return static_cast<const InDeProcess*>( Meta() );
}

void InDeInstance::ApplyTo( Image& image, Image* starsOutput ) const
{
   InDeInstance normalized( *this );
   normalized.NormalizeParameters();
   InDeWorker::Instance().Process( image, normalized, starsOutput );
}

bool InDeInstance::ExecuteOn( View& view )
{
   String whyNot;
   if ( !CanExecuteOn( view, whyNot ) )
      throw Error( whyNot );

   AutoViewLock lock( view );
   Console console;
   console.EnableAbort();
   console.WriteLn( "<end><cbr><br>" + InDeProductTitle( m_product ) + ": " + view.FullId().UTF8ToUTF16() );

   Image result;
   ImageVariant resultVariant( &result );
   resultVariant.AssignImage( view.Image() );

   Image stars;
   ApplyTo( result, m_product == InDeProduct::Stars && p_stars ? &stars : nullptr );

   ImageVariant target = view.Image();
   target.AssignImage( resultVariant );

   if ( !stars.IsEmpty() )
   {
      IsoString id = view.Id() + "_stars";
      ImageWindow output( stars.Width(), stars.Height(), stars.NumberOfChannels(),
                          32, true, stars.IsColor(), true, id );
      ImageVariant outputImage = output.MainView().Image();
      ImageVariant starsVariant( &stars );
      outputImage.AssignImage( starsVariant );
      output.Show();
      output.ZoomToFit();
   }

   console.WriteLn( "<end><cbr>Completed." );
   return true;
}

void* InDeInstance::LockParameter( const MetaParameter* parameter, size_type )
{
   const InDeParameterSet& p = ProcessMeta()->Parameters();
   if ( parameter == p.device ) return &p_device;
   if ( parameter == p.overlap ) return &p_overlap;
   if ( parameter == p.ss ) return &p_ss;
   if ( parameter == p.ash ) return &p_ash;
   if ( parameter == p.ansp ) return &p_ansp;
   if ( parameter == p.nsd ) return &p_nsd;
   if ( parameter == p.sn ) return &p_sn;
   if ( parameter == p.correctOnly ) return &p_correctOnly;
   if ( parameter == p.lunarPlanetary ) return &p_lunarPlanetary;
   if ( parameter == p.stars ) return &p_stars;
   if ( parameter == p.unscreen ) return &p_unscreen;
   if ( parameter == p.dn ) return &p_dn;
   if ( parameter == p.iterations ) return &p_iterations;
   if ( parameter == p.csep ) return &p_csep;
   if ( parameter == p.fsep ) return &p_fsep;
   if ( parameter == p.di ) return &p_di;
   if ( parameter == p.dc ) return &p_dc;
   if ( parameter == p.dhf ) return &p_dhf;
   if ( parameter == p.dlf ) return &p_dlf;
   if ( parameter == p.dihf ) return &p_dihf;
   if ( parameter == p.dilf ) return &p_dilf;
   if ( parameter == p.dchf ) return &p_dchf;
   if ( parameter == p.dclf ) return &p_dclf;
   if ( parameter == p.fs ) return &p_fs;
   return nullptr;
}

} // pcl
