#ifndef __InDeModule_h
#define __InDeModule_h

#include <pcl/MetaModule.h>

namespace pcl
{

class InDeModule : public MetaModule
{
public:
   const char* Version() const override;
   IsoString Name() const override;
   String Description() const override;
   String Company() const override;
   String Author() const override;
   String Copyright() const override;
   String TradeMarks() const override;
   String OriginalFileName() const override;
   void GetReleaseDate( int&, int&, int& ) const override;
   void OnUnload() override;
};

} // pcl

#endif
