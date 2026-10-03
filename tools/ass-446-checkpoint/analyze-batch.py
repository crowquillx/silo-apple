from pathlib import Path
import subprocess,sys,os,csv,json
out=Path(__file__).parent
prefix=sys.argv[1];files=sorted(out.glob(prefix+'-*.mov'))
env=dict(os.environ,PYTHONPATH=str(out/'analysis-libs'))
with (out/(prefix+'-analysis.log')).open('w') as log:
 for script in ['analyze-captures.py','analyze-motion-controls.py']:
  subprocess.run([sys.executable,str(out/script),*map(str,files)],env=env,stdout=log,stderr=subprocess.STDOUT,check=True)
 results=[]
 for p in files:
  motion=list(csv.DictReader((out/(p.stem+'-motion-verified.csv')).open()))
  frames={r['capture_frame']:r for r in csv.DictReader((out/(p.stem+'-frames.csv')).open())}
  bad=[];count=0
  for r in motion:
   if r['stage']!='track-alt' or not r['source_frame']:continue
   count+=1;expected='orange' if (int(r['source_frame'])//24)%2==0 else 'blue'
   actual=frames[r['capture_frame']]['cue_fill']
   if actual!=expected:bad.append({'frame':r['capture_frame'],'source':r['source_frame'],'expected':expected,'actual':actual})
  if count:results.append({'file':p.name,'alt_frames':count,'mismatches':bad})
 (out/(prefix+'-alt-track-color.json')).write_text(json.dumps(results,indent=2)+'\n')
