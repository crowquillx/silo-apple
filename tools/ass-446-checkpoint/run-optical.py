import subprocess,time,sys,signal,json
from pathlib import Path
out=Path(__file__).parent
platform,route=sys.argv[1:3]
suffix=sys.argv[3] if len(sys.argv)>3 else ""
device='47489DE2-CB74-4049-8FE1-7A541D345AE4' if platform=='ios' else 'D060E137-8D4B-46C0-ABDE-0C8368EC0862'
scheme='Silo' if platform=='ios' else 'SiloTV'; bundle='SiloTests' if platform=='ios' else 'SiloTVTests'
base=f'{platform}-{route}' + ('-'+suffix if suffix else ''); base += '-retry' if (out/f'{base}.xcresult').exists() else ''; logfile=out/f'{base}.log'
testmethod = f'ASSSubtitleLegacyCaptureTests/testIssue446At{route[6:]}FPS' if route.startswith('legacy') else f'ASSSubtitleOpticalCaptureTests/test{"Short" if suffix and not suffix.endswith("full") else "Extended"}{"Software" if route=="software" else "Native"}'
if 'animated' in suffix: testmethod = f'ASSSubtitleOpticalCaptureTests/test{"Extended" if suffix.endswith("full") else ""}Animated{"Software" if route=="software" else "Native"}'
if 'ssa' in suffix: testmethod = 'ASSSubtitleOpticalCaptureTests/testSSA' + ('Software' if route=='software' else 'Native')
if 'transport' in suffix: testmethod = 'ASSSubtitleOpticalCaptureTests/testTransport' + ('Software' if route=='software' else 'Native')
if route=='loopback':
 testmethod='ASSSubtitleOpticalCaptureTests/test' + ('TransportLoopback' if 'transport' in suffix else 'ExtendedAnimatedLoopback')
cmd=['xcodebuild'  ,'test-without-building','-project','/Users/m1/silo-446-optical/iosApp/Silo.xcodeproj','-scheme',scheme,'-destination',f'platform={"iOS" if platform=="ios" else "tvOS"} Simulator,id={device}','-derivedDataPath','/Users/m1/silo-446-build/OpticalDerivedData','-clonedSourcePackagesDirPath','/Users/m1/silo-446-build/SourcePackagesRebased','-only-testing',f'{bundle}/{testmethod}','-parallel-testing-enabled','NO','-resultBundlePath',str(out/f'{base}.xcresult')]
with logfile.open('w') as log:
 proc=subprocess.Popen(cmd,stdout=log,stderr=subprocess.STDOUT)
 active=None; stop_at=0; done=set(); recordings=[]
 triggers={'onset':10,'paused':8.4,'delay-positive':12.8,'off':11.2,'drift-end':5.8,'item-change':5}
 while proc.poll() is None:
  text=logfile.read_text(errors='replace')
  if active and time.monotonic()>=stop_at:
   active.send_signal(signal.SIGINT); active.wait(timeout=10); active=None
  if active is None:
   for name,duration in triggers.items():
    if name not in done and f'OPTICAL CASE {name} ' in text:
     done.add(name); path=out/f'{base}-{name}.mov'
     rec_log=(out/f'{base}-{name}-record.log').open('w')
     active=subprocess.Popen(['xcrun','simctl','io',device,'recordVideo','--codec=h264',str(path)],stdout=rec_log,stderr=subprocess.STDOUT)
     stop_at=time.monotonic()+duration; recordings.append({'scenario':name,'duration_requested':duration,'path':path.name,'start_monotonic':time.monotonic()})
     print(f'CAPTURING {base} {name}',flush=True); break
  time.sleep(.1)
 if active:
  active.send_signal(signal.SIGINT); active.wait(timeout=10)
(out/f'{base}-recordings.json').write_text(json.dumps(recordings,indent=2))
print('EXIT',proc.returncode,flush=True)
sys.exit(proc.returncode)
