import numpy as np,json,subprocess,csv,sys,re
from pathlib import Path
from PIL import Image
out=Path(__file__).parent;ff=(out/'ffmpeg-path.txt').read_text().strip()
stages=['delay-positive','delay-negative','speed-1.5','speed-0.5','seek-repeated','seek-forward','seek-back','track-sync','track-alt','item-change','drift-start','drift-end','paused','resume','resize','onset','off','on']
for name in sys.argv[1:]:
 p=Path(name);records=list(csv.DictReader((out/(p.stem+'-frames.csv')).open()));info=subprocess.run([ff,'-i',str(p)],stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True).stderr;w,h=map(int,re.search(r'Video:.*?, (\d{2,5})x(\d{2,5})[ ,]',info).groups());rh=round(h/w*640/2)*2
 proc=subprocess.Popen([ff,'-i',str(p),'-vf',f'scale=640:{rh}','-fps_mode','passthrough','-pix_fmt','rgb24','-f','rawvideo','-'],stdout=subprocess.PIPE,stderr=subprocess.DEVNULL)
 rows=[];dest=out/'timing-counters'/p.stem;dest.mkdir(parents=True,exist_ok=True);last=None;counter=None
 for idx,record in enumerate(records):
  raw=proc.stdout.read(640*rh*3)
  if len(raw)!=640*rh*3:break
  a=np.frombuffer(raw,np.uint8).reshape(rh,640,3)
  if not record['video_rect']:continue
  x0,y0,x1,y1=map(int,record['video_rect'].split(','));b=np.array(Image.fromarray(a[y0:y1,x0:x1]).resize((640,360)));header=a[max(0,y0-60):y0]
  mask=b[:40,:380].min(2)>185;tag=header.min(2)>185
  if last is None or np.count_nonzero(mask!=last[0])>2 or tag.shape!=last[1].shape or np.count_nonzero(tag!=last[1])>2:
   counter=dest/f'{idx:05d}.png';canvas=Image.new('RGB',(1520,350));canvas.paste(Image.fromarray(b[:50,:380]).resize((1520,200)),(0,0));canvas.paste(Image.fromarray(header).resize((1280,120)),(0,220));canvas.save(counter);last=(mask,tag)
  rows.append(dict(record,counter=counter.name))
 proc.wait();ocr=json.loads(subprocess.check_output([str(out/'ocr-frames')]+list(map(str,dest.glob('*.png')))));(out/(p.stem+'-timing-ocr.json')).write_text(json.dumps(ocr,indent=2));laststage='';isSoftware='software' in p.name
 for row in rows:
  text=' '.join(ocr.get(row['counter'],[]));m=re.search(r'(?:F[R]?A[MUV][E]?|FRAME|IFRAME)\s*(\d+)',text,re.I);source=int(m[1]) if m else None
  originalSource=source
  stamps=re.findall(r'(?<!\d)(\d{2})[:.\s_-]+(\d{2})[:.\s_-]+(\d{2})[:.\s_-]+(\d{3})(?!\d)', text.split('446',1)[0])
  fromStamp=None
  if stamps:
   hh,mm,ss,ms=map(int,stamps[-1]);fromStamp=round((hh*3600+mm*60+ss+ms/1000)*24)
  if source is not None and str(source).endswith('1'):
   shorter=int(str(source)[:-1] or '0')
   if source>2160 or fromStamp is not None and abs(shorter-fromStamp)<=1:source=shorter
  if source is None or source>2160:
   source=fromStamp if fromStamp is not None and fromStamp<=2160 else None

  for stage in stages:
   if stage in text: laststage=stage;break
  delay=.5 if laststage=='delay-positive' else -.5 if laststage=='delay-negative' else 0
  if laststage.startswith('speed'):delay=0
  offset=.021 if isSoftware and laststage!='track-alt' else 0
  pts=round(source/24+.021,3) if isSoftware and source is not None else source/24 if source is not None else None
  cueTime=pts-offset-delay if pts is not None else None
  expected='none' if laststage=='off' or cueTime is None or cueTime<2 else 'orange' if int(cueTime+1e-6)%2==0 else 'blue'
  row.update(source_frame=source,source_pts_s=pts,stage=laststage,delay_s=delay,expected_fill=expected,match=row['cue_fill']==expected)
 with (out/(p.stem+'-timing-verified.csv')).open('w') as f:
  wr=csv.DictWriter(f,fieldnames=list(rows[0]));wr.writeheader();wr.writerows(rows)
 bad=[r for r in rows if r['source_frame'] is not None and not r['match']];print(p.name,'rows',len(rows),'mismatches',len(bad),'unrecognized',sum(r['source_frame'] is None for r in rows),flush=True)
 print([(r['capture_frame'],r['source_frame'],r['stage'],r['cue_fill'],r['expected_fill']) for r in bad[:12]],flush=True)
