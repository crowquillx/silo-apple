import subprocess,re,json,csv,sys
from pathlib import Path
import numpy as np
from PIL import Image
out=Path(__file__).parent; ff=(out/'ffmpeg-path.txt').read_text().strip(); dest=out/'frames'; dest.mkdir(exist_ok=True)
for path in [Path(x) for x in sys.argv[1:]]:
 info=subprocess.run([ff,'-i',str(path)],stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True).stderr
 m=re.search(r'Video:.*?, (\d{2,5})x(\d{2,5})[ ,]',info); w,h=map(int,m.groups()); rw=640; rh=round(h/w*rw/2)*2
 logpath=out/(path.stem+'-decode.log')
 rows=[]; samples=[]; last=None
 with logpath.open('w') as log:
  p=subprocess.Popen([ff,'-i',str(path),'-vf',f'scale={rw}:{rh},showinfo','-fps_mode','passthrough','-pix_fmt','rgb24','-f','rawvideo','-'],stdout=subprocess.PIPE,stderr=log)
  idx=0
  while True:
   raw=p.stdout.read(rw*rh*3)
   if len(raw)!=rw*rh*3: break
   a=np.frombuffer(raw,np.uint8).reshape(rh,rw,3)
   orange=(a[:,:,0]>145)&(a[:,:,1]>35)&(a[:,:,1]<170)&(a[:,:,2]<100)
   blue=(a[:,:,0]<95)&(a[:,:,1]>45)&(a[:,:,1]<175)&(a[:,:,2]>115)
   mask=orange|blue; yy=np.where(mask.sum(axis=1)>rw*.3)[0]
   row={'capture_frame':idx,'background':'none','cue_fill':'none','white_pixels':0,'opposite_fill_pixels':0,'video_rect':''}
   if len(yy)>20:
    runs=np.split(yy,np.where(np.diff(yy)>1)[0]+1); yr=max(runs,key=len); y0,y1=int(yr[0]),int(yr[-1])+1
    xx=np.where(mask[y0:y1].sum(axis=0)>(y1-y0)*.35)[0]
    if len(xx)>100:
     x0,x1=int(xx[0]),int(xx[-1])+1; vh=y1-y0; vw=x1-x0
     # Bottom-left region excludes burned frame number and center subtitle.
     roi=a[y0+int(vh*.8):y0+int(vh*.9),x0+int(vw*.05):x0+int(vw*.15)]
     bg='orange' if roi[:,:,0].mean()>130 else 'blue'
     crop=a[y0+int(vh*.25):y0+int(vh*.75),x0+int(vw*.2):x0+int(vw*.8)]
     o=(crop[:,:,0]>145)&(crop[:,:,1]>35)&(crop[:,:,1]<170)&(crop[:,:,2]<100)
     b=(crop[:,:,0]<95)&(crop[:,:,1]>45)&(crop[:,:,1]<175)&(crop[:,:,2]>115)
     white=(crop.min(axis=2)>190); opposite=int((b if bg=='orange' else o).sum())
     wp=int(white.sum()); present=wp>max(25,vw*vh*.001)
     fill=('blue' if bg=='orange' else 'orange') if opposite>max(35,vw*vh*.002) else bg
     row.update(background=bg,cue_fill=fill if present else 'none',white_pixels=wp,opposite_fill_pixels=opposite,video_rect=f'{x0},{y0},{x1},{y1}')
     state=(bg,row['cue_fill'])
     if state!=last:
      name=f'{path.stem}-{idx:05d}'
      Image.fromarray(a).save(dest/(name+'.png'))
      # OCR only the burned source frame counter, enlarged for Vision.
      Image.fromarray(a[y0:y0+int(vh*.14),x0:x0+int(vw*.65)]).resize((int(vw*.65)*4,int(vh*.14)*4)).save(dest/(name+'-ocr.png'))
      samples.append({'capture_frame':idx,'image':name+'.png','ocr_image':name+'-ocr.png','background':bg,'cue_fill':row['cue_fill']})
      last=state
   rows.append(row); idx+=1
  p.wait()
 pts=re.findall(r' n:\s*\d+.*?pts_time:([\d.\-]+)',logpath.read_text())
 for i,row in enumerate(rows): row['capture_time_s']=float(pts[i]) if i<len(pts) else None
 with (out/(path.stem+'-frames.csv')).open('w') as f:
  wr=csv.DictWriter(f,fieldnames=['capture_frame','capture_time_s','background','cue_fill','white_pixels','opposite_fill_pixels','video_rect']);wr.writeheader();wr.writerows(rows)
 for s in samples: s['capture_time_s']=rows[s['capture_frame']]['capture_time_s']
 (out/(path.stem+'-transitions.json')).write_text(json.dumps(samples,indent=2))
 print(path.name,'frames',len(rows),'transitions',len(samples),flush=True)
