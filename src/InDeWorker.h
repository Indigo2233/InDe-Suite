#ifndef __InDeWorker_h
#define __InDeWorker_h

#include <pcl/ByteArray.h>
#include <pcl/ExternalProcess.h>
#include <pcl/Image.h>

#include <atomic>
#include <memory>
#include <mutex>

namespace pcl
{

class InDeInstance;

class InDeWorker
{
public:
   static InDeWorker& Instance();

   void Process( Image&, const InDeInstance&, Image* starsOutput );
   void Abort();
   void Shutdown();

private:
   InDeWorker() = default;
   ~InDeWorker();
   InDeWorker( const InDeWorker& ) = delete;
   InDeWorker& operator =( const InDeWorker& ) = delete;

   void EnsureStarted();
   void StopProcess( bool force );
   String FindInstallationRoot() const;
   IsoString BuildRequestJson( const Image&, const InDeInstance& ) const;
   void CheckCancellation( uint64 requestId );
   void DrainOutput( ByteArray&, ByteArray& );

   std::mutex m_requestMutex;
   std::mutex m_processMutex;
   std::unique_ptr<ExternalProcess> m_process;
   std::atomic<uint64> m_generation { 0 };
   bool m_requestActive = false; // guarded by m_processMutex
};

} // pcl

#endif
