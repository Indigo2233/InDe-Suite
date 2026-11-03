#ifndef __InDeProcess_h
#define __InDeProcess_h

#include <pcl/Image.h>
#include <pcl/MetaParameter.h>
#include <pcl/MetaProcess.h>
#include <pcl/ProcessImplementation.h>

namespace pcl
{

enum class InDeProduct
{
   Conv,
   Stars,
   Noise
};

IsoString InDeProductProcessId( InDeProduct );
String InDeProductTitle( InDeProduct );
IsoString InDeProductWorkerId( InDeProduct );

class InDeRealParameter : public MetaDouble
{
public:
   InDeRealParameter( MetaProcess*, const IsoString&, double, double, double, int );
   IsoString Id() const override;
   int Precision() const override;
   double MinimumValue() const override;
   double MaximumValue() const override;
   double DefaultValue() const override;

private:
   IsoString m_id;
   double m_minimum;
   double m_maximum;
   double m_default;
   int m_precision;
};

class InDeUIntParameter : public MetaUInt32
{
public:
   InDeUIntParameter( MetaProcess*, const IsoString&, uint32, uint32, uint32 );
   IsoString Id() const override;
   double MinimumValue() const override;
   double MaximumValue() const override;
   double DefaultValue() const override;

private:
   IsoString m_id;
   uint32 m_minimum;
   uint32 m_maximum;
   uint32 m_default;
};

class InDeBoolParameter : public MetaBoolean
{
public:
   InDeBoolParameter( MetaProcess*, const IsoString&, bool );
   IsoString Id() const override;
   bool DefaultValue() const override;

private:
   IsoString m_id;
   bool m_default;
};

class InDeDeviceParameter : public MetaEnumeration
{
public:
   // Append new entries to preserve saved Process Icons (0=Auto, 1=DML, 2=CPU).
   enum { Auto, DirectML, CPU, CoreML, NumberOfItems, Default = Auto };

   explicit InDeDeviceParameter( MetaProcess* );
   IsoString Id() const override;
   size_type NumberOfElements() const override;
   IsoString ElementId( size_type ) const override;
   int ElementValue( size_type ) const override;
   size_type DefaultValueIndex() const override;
};

struct InDeParameterSet
{
   explicit InDeParameterSet( MetaProcess*, InDeProduct );

   InDeDeviceParameter* device = nullptr;
   InDeRealParameter* overlap = nullptr;

   InDeRealParameter* ss = nullptr;
   InDeRealParameter* ash = nullptr;
   InDeBoolParameter* ansp = nullptr;
   InDeRealParameter* nsd = nullptr;
   InDeRealParameter* sn = nullptr;
   InDeBoolParameter* correctOnly = nullptr;
   InDeBoolParameter* lunarPlanetary = nullptr;

   InDeBoolParameter* stars = nullptr;
   InDeBoolParameter* unscreen = nullptr;

   InDeRealParameter* dn = nullptr;
   InDeUIntParameter* iterations = nullptr;
   InDeBoolParameter* csep = nullptr;
   InDeBoolParameter* fsep = nullptr;
   InDeRealParameter* di = nullptr;
   InDeRealParameter* dc = nullptr;
   InDeRealParameter* dhf = nullptr;
   InDeRealParameter* dlf = nullptr;
   InDeRealParameter* dihf = nullptr;
   InDeRealParameter* dilf = nullptr;
   InDeRealParameter* dchf = nullptr;
   InDeRealParameter* dclf = nullptr;
   InDeRealParameter* fs = nullptr;
};

class InDeProcess : public MetaProcess
{
public:
   explicit InDeProcess( InDeProduct );

   IsoString Id() const override;
   IsoString Category() const override;
   uint32 Version() const override;
   String Description() const override;
   ProcessInterface* DefaultInterface() const override;
   ProcessImplementation* Create() const override;
   ProcessImplementation* Clone( const ProcessImplementation& ) const override;
   bool NeedsValidation() const override;

   InDeProduct Product() const { return m_product; }
   const InDeParameterSet& Parameters() const { return m_parameters; }

private:
   InDeProduct m_product;
   InDeParameterSet m_parameters;
};

class InDeInstance : public ProcessImplementation
{
public:
   explicit InDeInstance( const InDeProcess* );
   InDeInstance( const InDeInstance& );

   void Assign( const ProcessImplementation& ) override;
   UndoFlags UndoMode( const View& ) const override;
   bool CanExecuteOn( const View&, String& ) const override;
   bool ExecuteOn( View& ) override;
   void* LockParameter( const MetaParameter*, size_type ) override;

   InDeProduct Product() const { return m_product; }
   const InDeProcess* ProcessMeta() const;
   void NormalizeParameters();
   void ApplyTo( Image&, Image* starsOutput = nullptr ) const;

private:
   InDeProduct m_product;

   pcl_enum p_device = InDeDeviceParameter::Default;
   double p_overlap = 0.2;

   double p_ss = 0.5;
   double p_ash = 0;
   pcl_bool p_ansp = true;
   double p_nsd = 0;
   double p_sn = 0.5;
   pcl_bool p_correctOnly = false;
   pcl_bool p_lunarPlanetary = false;

   pcl_bool p_stars = false;
   pcl_bool p_unscreen = false;

   double p_dn = 0.9;
   uint32 p_iterations = 2;
   pcl_bool p_csep = false;
   pcl_bool p_fsep = false;
   double p_di = 0.9;
   double p_dc = 0.9;
   double p_dhf = 0.9;
   double p_dlf = 0.9;
   double p_dihf = 0.9;
   double p_dilf = 0.9;
   double p_dchf = 0.9;
   double p_dclf = 0.9;
   double p_fs = 5;

   friend class InDeWorker;
   friend class InDeInterface;
};

extern InDeProcess* TheInDeConvProcess;
extern InDeProcess* TheInDeStarsProcess;
extern InDeProcess* TheInDeNoiseProcess;

} // pcl

#endif
