#include "InDeInterface.h"
#include "InDeWorker.h"

#include <pcl/Console.h>
#include <pcl/Exception.h>
#include <pcl/RealTimePreview.h>

namespace pcl
{

InDeInterface* TheInDeConvInterface = nullptr;
InDeInterface* TheInDeStarsInterface = nullptr;
InDeInterface* TheInDeNoiseInterface = nullptr;

InDeInterface::InDeInterface( InDeProduct product, InDeProcess* process )
   : m_product( product )
   , m_process( process )
   , m_instance( process )
{
   switch ( product )
   {
   case InDeProduct::Conv:  TheInDeConvInterface = this; break;
   case InDeProduct::Stars: TheInDeStarsInterface = this; break;
   case InDeProduct::Noise: TheInDeNoiseInterface = this; break;
   }
}

InDeInterface::~InDeInterface()
{
   if ( GUI != nullptr )
      delete GUI, GUI = nullptr;
}

IsoString InDeInterface::Id() const
{
   return InDeProductProcessId( m_product );
}

MetaProcess* InDeInterface::Process() const
{
   return m_process;
}

InterfaceFeatures InDeInterface::Features() const
{
   return InterfaceFeature::Default |
          InterfaceFeature::RealTimeButton |
          InterfaceFeature::RealTimeF32Images;
}

void InDeInterface::RealTimePreviewUpdated( bool active )
{
   if ( GUI == nullptr )
      return;
   if ( active )
   {
      m_cancelled = false;
      RealTimePreview::SetOwner( *this );
   }
   else
   {
      CancelRealTimePreview();
      RealTimePreview::SetOwner( ProcessInterface::Null() );
   }
}

void InDeInterface::ApplyInstance() const
{
   m_instance.LaunchOnCurrentView();
}

void InDeInterface::ResetInstance()
{
   InDeInstance instance( m_process );
   ImportProcess( instance );
}

bool InDeInterface::Launch( const MetaProcess& process, const ProcessImplementation*,
                             bool& dynamic, unsigned& )
{
   if ( &process != m_process )
      return false;

   if ( GUI == nullptr )
   {
      GUI = new GUIData( *this );
      SetWindowTitle( InDeProductTitle( m_product ) );
      UpdateControls();
   }
   dynamic = false;
   return true;
}

ProcessImplementation* InDeInterface::NewProcess() const
{
   return new InDeInstance( m_instance );
}

bool InDeInterface::ValidateProcess( const ProcessImplementation& implementation, String& whyNot ) const
{
   const InDeInstance* instance = dynamic_cast<const InDeInstance*>( &implementation );
   if ( instance != nullptr && instance->Product() == m_product )
      return true;
   whyNot = "Incompatible " + InDeProductTitle( m_product ) + " process instance.";
   return false;
}

bool InDeInterface::RequiresInstanceValidation() const
{
   return true;
}

bool InDeInterface::ImportProcess( const ProcessImplementation& implementation )
{
   String whyNot;
   if ( !ValidateProcess( implementation, whyNot ) )
      return false;
   m_instance.Assign( implementation );
   if ( GUI != nullptr )
      UpdateControls();
   ScheduleRealTimePreviewUpdate();
   return true;
}

bool InDeInterface::RequiresRealTimePreviewUpdate( const Image&, const View&, const Rect&, int ) const
{
   return true;
}

bool InDeInterface::GenerateRealTimePreview( Image& image, const View&, const Rect&, int, String& info ) const
{
   try
   {
      if ( m_cancelled )
         return false;
      m_instance.ApplyTo( image );
      if ( m_cancelled )
         return false;
      info = InDeProductTitle( m_product );
      return true;
   }
   catch ( const ProcessAborted& )
   {
      return false;
   }
   catch ( const Exception& error )
   {
      info = error.Message();
      Console().WarningLn( "<end><cbr>" + InDeProductTitle( m_product ) + " Real-Time Preview: " + error.Message() );
      return false;
   }
   catch ( ... )
   {
      info = InDeProductTitle( m_product ) + " Real-Time Preview failed.";
      return false;
   }
}

void InDeInterface::CancelRealTimePreview()
{
   m_cancelled = true;
   InDeWorker::Instance().Abort();
}

void InDeInterface::UpdateControls()
{
   if ( GUI == nullptr )
      return;

   GUI->Device_ComboBox.SetCurrentItem( int( m_instance.p_device ) );
   GUI->Overlap_NumericControl.SetValue( m_instance.p_overlap );

   if ( m_product == InDeProduct::Conv )
   {
      GUI->SS_NumericControl.SetValue( m_instance.p_ss );
      GUI->ASH_NumericControl.SetValue( m_instance.p_ash );
      GUI->ANSP_CheckBox.SetChecked( m_instance.p_ansp );
      GUI->NSD_NumericControl.SetValue( m_instance.p_nsd );
      GUI->SN_NumericControl.SetValue( m_instance.p_sn );
      GUI->CorrectOnly_CheckBox.SetChecked( m_instance.p_correctOnly );
      GUI->LunarPlanetary_CheckBox.SetChecked( m_instance.p_lunarPlanetary );

      bool correctOnly = m_instance.p_correctOnly;
      bool lunarPlanetary = m_instance.p_lunarPlanetary && !correctOnly;
      GUI->LunarPlanetary_CheckBox.Enable( !correctOnly );
      GUI->SS_NumericControl.Enable( !correctOnly && !lunarPlanetary );
      GUI->ASH_NumericControl.Enable( !correctOnly && !lunarPlanetary );
      GUI->ANSP_CheckBox.Enable( !correctOnly && !lunarPlanetary );
      GUI->NSD_NumericControl.Enable( !correctOnly && (lunarPlanetary || !m_instance.p_ansp) );
      GUI->SN_NumericControl.Enable( !correctOnly );
   }
   else if ( m_product == InDeProduct::Stars )
   {
      GUI->Stars_CheckBox.SetChecked( m_instance.p_stars );
      GUI->Unscreen_CheckBox.SetChecked( m_instance.p_unscreen );
      GUI->Unscreen_CheckBox.Enable( m_instance.p_stars );
   }
   else
   {
      bool color = m_instance.p_csep;
      bool frequency = m_instance.p_fsep;
      GUI->Csep_CheckBox.SetChecked( color );
      GUI->Fsep_CheckBox.SetChecked( frequency );
      GUI->DN_NumericControl.SetValue( m_instance.p_dn );
      GUI->DI_NumericControl.SetValue( m_instance.p_di );
      GUI->DC_NumericControl.SetValue( m_instance.p_dc );
      GUI->DHF_NumericControl.SetValue( m_instance.p_dhf );
      GUI->DLF_NumericControl.SetValue( m_instance.p_dlf );
      GUI->DIHF_NumericControl.SetValue( m_instance.p_dihf );
      GUI->DILF_NumericControl.SetValue( m_instance.p_dilf );
      GUI->DCHF_NumericControl.SetValue( m_instance.p_dchf );
      GUI->DCLF_NumericControl.SetValue( m_instance.p_dclf );
      GUI->FS_NumericControl.SetValue( m_instance.p_fs );
      GUI->Iterations_NumericControl.SetValue( m_instance.p_iterations );

      GUI->DN_NumericControl.Enable( !color && !frequency );
      GUI->DI_NumericControl.Enable( color && !frequency );
      GUI->DC_NumericControl.Enable( color && !frequency );
      GUI->DHF_NumericControl.Enable( !color && frequency );
      GUI->DLF_NumericControl.Enable( !color && frequency );
      GUI->DIHF_NumericControl.Enable( color && frequency );
      GUI->DILF_NumericControl.Enable( color && frequency );
      GUI->DCHF_NumericControl.Enable( color && frequency );
      GUI->DCLF_NumericControl.Enable( color && frequency );
      GUI->FS_NumericControl.Enable( frequency );
   }
}

void InDeInterface::ScheduleRealTimePreviewUpdate()
{
   if ( GUI != nullptr && IsRealTimePreviewActive() )
   {
      CancelRealTimePreview();
      GUI->Update_Timer.Start();
   }
}

void InDeInterface::__Device_ItemSelected( ComboBox&, int item )
{
   m_instance.p_device = pcl_enum( item );
   ScheduleRealTimePreviewUpdate();
}

void InDeInterface::__ValueUpdated( NumericEdit& sender, double value )
{
   if ( sender == GUI->Overlap_NumericControl ) m_instance.p_overlap = value;
   else if ( sender == GUI->SS_NumericControl ) m_instance.p_ss = value;
   else if ( sender == GUI->ASH_NumericControl ) m_instance.p_ash = value;
   else if ( sender == GUI->NSD_NumericControl ) m_instance.p_nsd = value;
   else if ( sender == GUI->SN_NumericControl ) m_instance.p_sn = value;
   else if ( sender == GUI->DN_NumericControl ) m_instance.p_dn = value;
   else if ( sender == GUI->DI_NumericControl ) m_instance.p_di = value;
   else if ( sender == GUI->DC_NumericControl ) m_instance.p_dc = value;
   else if ( sender == GUI->DHF_NumericControl ) m_instance.p_dhf = value;
   else if ( sender == GUI->DLF_NumericControl ) m_instance.p_dlf = value;
   else if ( sender == GUI->DIHF_NumericControl ) m_instance.p_dihf = value;
   else if ( sender == GUI->DILF_NumericControl ) m_instance.p_dilf = value;
   else if ( sender == GUI->DCHF_NumericControl ) m_instance.p_dchf = value;
   else if ( sender == GUI->DCLF_NumericControl ) m_instance.p_dclf = value;
   else if ( sender == GUI->FS_NumericControl ) m_instance.p_fs = value;
   else if ( sender == GUI->Iterations_NumericControl ) m_instance.p_iterations = uint32( value );
   ScheduleRealTimePreviewUpdate();
}

void InDeInterface::__ButtonClicked( Button& sender, bool checked )
{
   if ( sender == GUI->ANSP_CheckBox ) m_instance.p_ansp = checked;
   else if ( sender == GUI->CorrectOnly_CheckBox ) m_instance.p_correctOnly = checked;
   else if ( sender == GUI->LunarPlanetary_CheckBox ) m_instance.p_lunarPlanetary = checked;
   else if ( sender == GUI->Stars_CheckBox ) m_instance.p_stars = checked;
   else if ( sender == GUI->Unscreen_CheckBox ) m_instance.p_unscreen = checked;
   else if ( sender == GUI->Csep_CheckBox ) m_instance.p_csep = checked;
   else if ( sender == GUI->Fsep_CheckBox ) m_instance.p_fsep = checked;

   m_instance.NormalizeParameters();
   UpdateControls();
   ScheduleRealTimePreviewUpdate();
}

void InDeInterface::__Update_Timer( Timer& )
{
   if ( IsRealTimePreviewActive() )
   {
      m_cancelled = false;
      RealTimePreview::Update();
   }
}

InDeInterface::GUIData::GUIData( InDeInterface& w )
{
   pcl::Font fnt = w.Font();
   int labelWidth = fnt.Width( String( "Denoise HF Intensity:" ) + 'T' );

   Device_Label.SetText( "Compute device:" );
   Device_Label.SetTextAlignment( TextAlign::Right | TextAlign::VertCenter );
   Device_Label.SetFixedWidth( labelWidth );
#ifdef __PCL_MACOSX
   Device_ComboBox.AddItem( "Auto (CPU)" );
   Device_ComboBox.AddItem( "DirectML (Windows only)" );
#else
   Device_ComboBox.AddItem( "Auto (DirectML / CPU)" );
   Device_ComboBox.AddItem( "DirectML GPU" );
#endif
   Device_ComboBox.AddItem( "CPU" );
   Device_ComboBox.AddItem( "Core ML (macOS, experimental)" );
   Device_ComboBox.OnItemSelected(
      (ComboBox::item_event_handler)&InDeInterface::__Device_ItemSelected, w );
   Device_Sizer.SetSpacing( 4 );
   Device_Sizer.Add( Device_Label );
   Device_Sizer.Add( Device_ComboBox, 100 );

   auto setupReal = [&]( NumericControl& control, const char* label,
                         double minimum, double maximum, int precision,
                         bool exponential = false )
   {
      control.label.SetText( label );
      control.label.SetFixedWidth( labelWidth );
      control.slider.SetRange( 0, 1000 );
      control.slider.SetScaledMinWidth( 260 );
      control.SetReal();
      control.SetRange( minimum, maximum );
      control.SetPrecision( precision );
      if ( exponential )
         control.EnableExponentialResponse();
      control.OnValueUpdated(
         (NumericEdit::value_event_handler)&InDeInterface::__ValueUpdated, w );
   };

   setupReal( Overlap_NumericControl, "Tile overlap:", 0, 0.5, 2 );
   Common_Sizer.SetMargin( 6 );
   Common_Sizer.SetSpacing( 4 );
   Common_Sizer.Add( Device_Sizer );
   Common_Sizer.Add( Overlap_NumericControl );
   Common_GroupBox.SetTitle( "Execution" );
   Common_GroupBox.SetSizer( Common_Sizer );

   auto setupCheck = [&]( CheckBox& control, const char* text )
   {
      control.SetText( text );
      control.OnClick( (Button::click_event_handler)&InDeInterface::__ButtonClicked, w );
   };

   Product_Sizer.SetMargin( 6 );
   Product_Sizer.SetSpacing( 4 );

   if ( w.m_product == InDeProduct::Conv )
   {
      Product_GroupBox.SetTitle( "Blur correction and sharpening" );
      setupReal( SS_NumericControl, "Sharpen Stars:", 0, 0.7, 2 );
      setupReal( ASH_NumericControl, "Adjust Star Halos:", -0.5, 0.5, 2 );
      setupCheck( ANSP_CheckBox, "Automatic PSF" );
      setupReal( NSD_NumericControl, "PSF Diameter (pixels):", 0, 8, 1 );
      setupReal( SN_NumericControl, "Sharpen Nonstellar:", 0, 1, 2 );
      setupCheck( CorrectOnly_CheckBox, "Correct Only" );
      setupCheck( LunarPlanetary_CheckBox, "Lunar / Planetary Mode" );
      Product_Sizer.Add( SS_NumericControl );
      Product_Sizer.Add( ASH_NumericControl );
      Product_Sizer.Add( ANSP_CheckBox );
      Product_Sizer.Add( NSD_NumericControl );
      Product_Sizer.Add( SN_NumericControl );
      Product_Sizer.Add( CorrectOnly_CheckBox );
      Product_Sizer.Add( LunarPlanetary_CheckBox );
   }
   else if ( w.m_product == InDeProduct::Stars )
   {
      Product_GroupBox.SetTitle( "Star removal" );
      setupCheck( Stars_CheckBox, "Generate Star Image" );
      setupCheck( Unscreen_CheckBox, "Unscreen Stars" );
      Product_Sizer.Add( Stars_CheckBox );
      Product_Sizer.Add( Unscreen_CheckBox );
   }
   else
   {
      Product_GroupBox.SetTitle( "Noise reduction" );
      setupCheck( Csep_CheckBox, "Intensity / Color Separation" );
      setupCheck( Fsep_CheckBox, "Frequency Separation" );
      setupReal( DN_NumericControl, "Denoise:", 0, 1, 2 );
      setupReal( DI_NumericControl, "Denoise Intensity:", 0, 1, 2 );
      setupReal( DC_NumericControl, "Denoise Color:", 0, 1, 2 );
      setupReal( DHF_NumericControl, "Denoise HF:", 0, 1, 2 );
      setupReal( DLF_NumericControl, "Denoise LF:", 0, 1, 2 );
      setupReal( DIHF_NumericControl, "Denoise HF Intensity:", 0, 1, 2 );
      setupReal( DILF_NumericControl, "Denoise LF Intensity:", 0, 1, 2 );
      setupReal( DCHF_NumericControl, "Denoise HF Color:", 0, 1, 2 );
      setupReal( DCLF_NumericControl, "Denoise LF Color:", 0, 1, 2 );
      setupReal( FS_NumericControl, "HF/LF Scale (pixels):", 1, 100, 1, true );
      setupReal( Iterations_NumericControl, "Iterations:", 1, 5, 0 );
      Iterations_NumericControl.SetInteger();
      Product_Sizer.Add( Csep_CheckBox );
      Product_Sizer.Add( Fsep_CheckBox );
      Product_Sizer.Add( DN_NumericControl );
      Product_Sizer.Add( DI_NumericControl );
      Product_Sizer.Add( DC_NumericControl );
      Product_Sizer.Add( DHF_NumericControl );
      Product_Sizer.Add( DLF_NumericControl );
      Product_Sizer.Add( DIHF_NumericControl );
      Product_Sizer.Add( DILF_NumericControl );
      Product_Sizer.Add( DCHF_NumericControl );
      Product_Sizer.Add( DCLF_NumericControl );
      Product_Sizer.Add( FS_NumericControl );
      Product_Sizer.Add( Iterations_NumericControl );
   }

   Product_GroupBox.SetSizer( Product_Sizer );
   Global_Sizer.SetMargin( 6 );
   Global_Sizer.SetSpacing( 6 );
   Global_Sizer.Add( Common_GroupBox );
   Global_Sizer.Add( Product_GroupBox );

   w.SetSizer( Global_Sizer );
   w.EnsureLayoutUpdated();
   w.AdjustToContents();
   w.SetFixedSize();

   Update_Timer.SetSingleShot();
   Update_Timer.SetInterval( 0.35 );
   Update_Timer.OnTimer( (Timer::timer_event_handler)&InDeInterface::__Update_Timer, w );
}

} // pcl
