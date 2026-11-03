#ifndef __InDeInterface_h
#define __InDeInterface_h

#include "InDeProcess.h"

#include <pcl/CheckBox.h>
#include <pcl/ComboBox.h>
#include <pcl/GroupBox.h>
#include <pcl/Label.h>
#include <pcl/NumericControl.h>
#include <pcl/ProcessInterface.h>
#include <pcl/Sizer.h>
#include <pcl/Timer.h>

#include <atomic>

namespace pcl
{

class InDeInterface : public ProcessInterface
{
public:
   InDeInterface( InDeProduct, InDeProcess* );
   ~InDeInterface() override;

   IsoString Id() const override;
   MetaProcess* Process() const override;
   InterfaceFeatures Features() const override;
   void RealTimePreviewUpdated( bool ) override;
   void ApplyInstance() const override;
   void ResetInstance() override;
   bool Launch( const MetaProcess&, const ProcessImplementation*, bool&, unsigned& ) override;
   ProcessImplementation* NewProcess() const override;
   bool ValidateProcess( const ProcessImplementation&, String& ) const override;
   bool RequiresInstanceValidation() const override;
   bool ImportProcess( const ProcessImplementation& ) override;
   bool RequiresRealTimePreviewUpdate( const Image&, const View&, const Rect&, int ) const override;
   bool GenerateRealTimePreview( Image&, const View&, const Rect&, int, String& ) const override;
   void CancelRealTimePreview() override;

private:
   InDeProduct m_product;
   InDeProcess* m_process;
   InDeInstance m_instance;
   mutable std::atomic_bool m_cancelled { false };

   struct GUIData
   {
      explicit GUIData( InDeInterface& );

      VerticalSizer Global_Sizer;
         GroupBox Common_GroupBox;
         VerticalSizer Common_Sizer;
            HorizontalSizer Device_Sizer;
               Label Device_Label;
               ComboBox Device_ComboBox;
            NumericControl Overlap_NumericControl;

         GroupBox Product_GroupBox;
         VerticalSizer Product_Sizer;
            NumericControl SS_NumericControl;
            NumericControl ASH_NumericControl;
            CheckBox ANSP_CheckBox;
            NumericControl NSD_NumericControl;
            NumericControl SN_NumericControl;
            CheckBox CorrectOnly_CheckBox;
            CheckBox LunarPlanetary_CheckBox;

            CheckBox Stars_CheckBox;
            CheckBox Unscreen_CheckBox;

            CheckBox Csep_CheckBox;
            CheckBox Fsep_CheckBox;
            NumericControl DN_NumericControl;
            NumericControl DI_NumericControl;
            NumericControl DC_NumericControl;
            NumericControl DHF_NumericControl;
            NumericControl DLF_NumericControl;
            NumericControl DIHF_NumericControl;
            NumericControl DILF_NumericControl;
            NumericControl DCHF_NumericControl;
            NumericControl DCLF_NumericControl;
            NumericControl FS_NumericControl;
            NumericControl Iterations_NumericControl;

      Timer Update_Timer;
   };

   GUIData* GUI = nullptr;

   void UpdateControls();
   void ScheduleRealTimePreviewUpdate();
   void __Device_ItemSelected( ComboBox&, int );
   void __ValueUpdated( NumericEdit&, double );
   void __ButtonClicked( Button&, bool );
   void __Update_Timer( Timer& );
};

extern InDeInterface* TheInDeConvInterface;
extern InDeInterface* TheInDeStarsInterface;
extern InDeInterface* TheInDeNoiseInterface;

} // pcl

#endif
