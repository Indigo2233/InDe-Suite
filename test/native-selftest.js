#engine v8

(function()
{
   let reportPath = File.systemTempDirectory + "/inde-native-selftest.json";
   File.writeTextFile( reportPath, JSON.stringify( { stage: "script-started" } ) );
   let report = { ok: false, tests: [], error: "" };
   let windows = [];

   function makeImage( id, size )
   {
      let window = new ImageWindow( size, size, 1, 32, true, false, id );
      windows.push( window );
      window.mainView.beginProcess( UndoFlag.NoSwapFile );
      try
      {
         let samples = new Float32Array( size*size );
         for ( let y = 0; y < size; ++y )
            for ( let x = 0; x < size; ++x )
               samples[y*size + x] = 0.08 + 0.6*x/(size - 1) + 0.2*y/(size - 1);
         window.mainView.image.setSamples( samples, new Rect( 0, 0, size, size ), 0 );
      }
      finally
      {
         window.mainView.endProcess();
      }
      return window;
   }

   function run( name, constructor, configure, size )
   {
      let window = makeImage( "InDeTest_" + name, size );
      let process = new constructor;
      configure( process );
      let started = Date.now();
      if ( !process.executeOn( window.mainView ) )
         throw new Error( name + " executeOn() returned false" );
      report.tests.push( {
         process: name,
         width: window.mainView.image.width,
         height: window.mainView.image.height,
         elapsedMs: Date.now() - started,
         mean: window.mainView.image.mean()
      } );
   }

   try
   {
      run( "InDeConv", InDeConv, function( process )
      {
         process.device = 0;
         process.overlap = 0.2;
         process.sharpenStars = 0.5;
         process.adjustStarHalos = 0;
         process.automaticPSF = true;
         process.psfDiameter = 0;
         process.sharpenNonstellar = 0.5;
         process.correctOnly = false;
         process.lunarPlanetary = false;
      }, 32 );

      run( "InDeStars", InDeStars, function( process )
      {
         process.device = 0;
         process.overlap = 0.2;
         process.generateStars = false;
         process.unscreenStars = false;
      }, 16 );

      run( "InDeNoise", InDeNoise, function( process )
      {
         process.device = 0;
         process.overlap = 0.2;
         process.denoise = 0.9;
         process.iterations = 2;
         process.intensityColorSeparation = false;
         process.frequencySeparation = false;
      }, 16 );

      report.ok = true;
   }
   catch ( error )
   {
      report.error = String( error.message || error );
   }
   finally
   {
      for ( let window of windows )
         if ( window != null && !window.isNull )
            window.forceClose();
      File.writeTextFile( reportPath, JSON.stringify( report, null, 2 ) );
   }
})();
