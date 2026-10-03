from pathlib import Path
import subprocess
out=Path('/Users/m1/silo-446-build/validation-20261003-032038'); fixtures=out/'fixtures'; fixtures.mkdir(exist_ok=True)
ff=(out/'ffmpeg-path.txt').read_text().strip()
header=(out/'original.ass').read_text().split('Dialogue:')[0]
def ts(i): return f'0:{i//60:02}:{i%60:02}.00'
lines=[]
for i in range(2,90):
 c='002A5BEA' if i%2==0 else '00AA6917'
 lines.append(f'Dialogue: 0,{ts(i)},{ts(i+1)},Default,,0,0,0,,{{\\1c&H{c}&}}SYNC')
(fixtures/'sync.ass').write_text(header+'\n'.join(lines)+'\n')
(fixtures/'alt.ass').write_text((fixtures/'sync.ass').read_text().replace('SYNC','ALT'))
font='/System/Library/Fonts/Monaco.ttf'
vf=f"drawbox=x=0:y=0:w=iw:h=ih:color=0xEA5B2A:t=fill:enable='eq(mod(floor(t),2),0)',drawtext=fontfile={font}:text='FRAME %{{n}}  SOURCE %{{pts\\:hms}}':x=20:y=20:fontsize=24:fontcolor=white:box=1:boxcolor=black"
cmd=[ff,'-y','-f','lavfi','-i','color=c=0x1769AA:s=1280x720:r=24:d=90','-f','lavfi','-i','anullsrc=r=48000:cl=stereo','-vf',vf,'-t','90','-c:v','libx264','-preset','ultrafast','-crf','18','-g','48','-pix_fmt','yuv420p','-c:a','aac','-movflags','+faststart',str(fixtures/'sync.mp4')]
with (out/'fixture-generation.log').open('w') as log:
 subprocess.run(cmd,stderr=log,check=True)
 subprocess.run([ff,'-y','-i',str(fixtures/'sync.mp4'),'-i',str(fixtures/'sync.ass'),'-map','0:v','-map','0:a','-map','1:s','-c','copy',str(fixtures/'sync.mkv')],stderr=log,check=True)
 (fixtures/'hls').mkdir(exist_ok=True)
 subprocess.run([ff,'-y','-i',str(fixtures/'sync.mp4'),'-c','copy','-hls_time','2','-hls_playlist_type','vod','-hls_segment_type','fmp4','-hls_segment_filename',str(fixtures/'hls/segment%03d.m4s'),str(fixtures/'hls/media.m3u8')],stderr=log,check=True)
print('FIXTURES READY')
