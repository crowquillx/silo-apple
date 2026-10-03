import numpy as np,json,subprocess,csv,sys,re
from pathlib import Path
from PIL import Image
out=Path(__file__).parent; ff=(out/'ffmpeg-path.txt').read_text().strip()
stages=['delay-positive','delay-negative','speed-1.5','speed-0.5','seek-repeated','seek-forward','seek-back','track-sync','track-alt','item-change','drift-start','drift-end','paused','resume','resize','onset','off','on']
for name in sys.argv[1:]:
 p=Path(name); records=list(csv.DictReader((out/(p.stem+'-frames.csv')).open()));i=subprocess.run([ff,'-i',str(p)],stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True).stderr;w,h=map(int,re.search(r'Video:.*?, (\d{2,5})x(\d{2,5})[ ,]',i).groups());rh=round(h/w*640/2)*2
 proc=subprocess.Popen([ff,'-i',str(p),'-fps_mode','passthrough','-pix_fmt','rgb24','-f','rawvideo','-'],stdout=subprocess.PIPE,stderr=subprocess.DEVNULL)
 rows=[];dest=out/'motion-counters-v2'/p.stem;dest.mkdir(parents=True,exist_ok=True);lastcounter=None;counter=None
 for idx,record in enumerate(records):
  raw=proc.stdout.read(w*h*3)
  if len(raw)!=w*h*3: break
  full=np.frombuffer(raw,np.uint8).reshape(h,w,3)
  a=np.array(Image.fromarray(full).resize((640,rh)))
  if not record['video_rect']:continue
  x0,y0,x1,y1=map(int,record['video_rect'].split(','));b=np.array(Image.fromarray(a[y0:y1,x0:x1]).resize((640,360)))
  fx0,fy0,fx1,fy1=round(x0*w/640),round(y0*h/rh),round(x1*w/640),round(y1*h/rh)
  bw,bh=fx1-fx0,fy1-fy0
  burned=full[fy0:fy0+round(bh*.14),fx0:fx0+round(bw*.65)]
  originalHeader=full[max(0,fy0-round(60*h/rh)):fy0]
  def changed(current,previous):
   return current.shape!=previous.shape or np.any(np.abs(current.astype(np.int16)-previous.astype(np.int16))>12)
  if lastcounter is None or changed(burned,lastcounter[0]) or changed(originalHeader,lastcounter[1]):
   counter=dest/f'{idx:05d}.png'
   canvas=Image.new('RGB',(2400,460));canvas.paste(Image.fromarray(burned).resize((2400,280)),(0,0));canvas.paste(Image.fromarray(originalHeader).resize((1920,160)),(0,300));canvas.save(counter);lastcounter=(burned.copy(),originalHeader.copy())
  white=b[130:225].min(2)>190;xx=np.where(white.sum(0)>4)[0];pos=float(xx.min()*2) if len(xx) else None
  rows.append({'capture_frame':idx,'capture_time_s':record['capture_time_s'],'counter':counter.name,'observed_left_source_pixels':pos})
 proc.wait()
 ocr=json.loads(subprocess.check_output([str(out/'ocr-frames')]+list(map(str,dest.glob('*.png')))))
 (out/(p.stem+'-motion-ocr.json')).write_text(json.dumps(ocr,indent=2))
 laststage=''; previousSource=None; resolvedCounters={}
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

  if row['counter'] in resolvedCounters:
   source=resolvedCounters[row['counter']]
  else:
   if source is not None and str(source).endswith('1') and previousSource is not None:
    shorter=int(str(source)[:-1] or '0')
    if abs(source-previousSource)>24 and abs(shorter-previousSource)<=4:source=shorter
   resolvedCounters[row['counter']]=source
  if source is not None:previousSource=source
  for stage in stages:
   if stage in text:laststage=stage;break
  delay=.5 if laststage=='delay-positive' else -.5 if laststage=='delay-negative' else 0
  cueTime=((round((source/24+.021)*1000)-21)/1000 if 'software' in p.name else source/24)-delay if source is not None else None
  expected=196+800*(int((cueTime+1e-8)*1000)/1000%1) if cueTime is not None and cueTime>=2 and laststage not in ('off','track-alt') else None
  row.update(ocr_frame=originalSource,ocr_stamp_frame=fromStamp,stage=laststage,delay_s=delay,match=(abs(row['observed_left_source_pixels']-expected)<=4 if expected is not None and row['observed_left_source_pixels'] is not None else expected is None and row['observed_left_source_pixels'] is None) if laststage!='track-alt' else None,source_frame=source,source_time_s=source/24 if source is not None else None,expected_left_source_pixels=expected,position_error_source_pixels=row['observed_left_source_pixels']-expected if row['observed_left_source_pixels'] is not None and expected is not None else None)
 with (out/(p.stem+'-motion-verified.csv')).open('w') as f:
  wr=csv.DictWriter(f,fieldnames=list(rows[0]));wr.writeheader();wr.writerows(rows)
 vals=[x['position_error_source_pixels'] for x in rows if x['position_error_source_pixels'] is not None]
 holes=[x for x in rows if x['source_frame'] is not None and x['expected_left_source_pixels'] is not None and x['observed_left_source_pixels'] is None]
 print(p.name,'error range source px',min(vals) if vals else None,max(vals) if vals else None,'holes',len(holes),'unrecognized',sum(x['source_frame'] is None for x in rows),flush=True)

 bad=[x for x in rows if x['match'] is False];print('mismatches',len(bad),[(x['capture_frame'],x['source_frame'],x['stage'],x['position_error_source_pixels']) for x in bad[:15]],flush=True)
