#!/usr/bin/env python3
"""Validate retained smoke artifacts: python3 tool/validate_smoke.py LOG OUTPUT_DIR.
Requires external ffprobe/ffmpeg for QA only; neither is used by the plugin.
"""
import re,base64,json,subprocess,hashlib,array,math,sys
from pathlib import Path
log=Path(sys.argv[1]).read_text();out=Path(sys.argv[2]);out.mkdir(parents=True,exist_ok=True);report={}
for name in ['silent.mp4','mixed.mp4']:
 parts=re.findall(r'COOKOO_ARTIFACT:'+re.escape(name)+r':(\d+):([A-Za-z0-9+/=]+)',log)
 ordered=sorted((int(i),x)for i,x in parts)
 assert ordered and all(i==j*900 for j,(i,x) in enumerate(ordered)),name+' incomplete artifacts'
 f=out/name;f.write_bytes(base64.b64decode(''.join(x for _,x in ordered)))
 info=json.loads(subprocess.check_output(['ffprobe','-v','error','-count_frames','-show_streams','-of','json',str(f)]))
 subprocess.run(['ffmpeg','-v','error','-i',str(f),'-f','null','-'],check=True,capture_output=True)
 video=subprocess.check_output(['ffmpeg','-v','error','-i',str(f),'-map','0:v:0','-c','copy','-f','data','-'])
 report[name]={'streams':[{k:s.get(k)for k in ['codec_name','width','height','r_frame_rate','avg_frame_rate','duration','nb_read_frames','sample_rate','channels']}for s in info['streams']],'video_sha256':hashlib.sha256(video).hexdigest(),'full_decode':'passed'}
 v=next(s for s in info['streams']if s['codec_type']=='video')
 assert int(v['nb_read_frames'])==61
 assert (v['width'],v['height'])==(640,360)
 assert abs(float(v['duration'])-61*1001/30000)<.001
 assert v['r_frame_rate']==v['avg_frame_rate']=='30000/1001'
 for audio in (s for s in info['streams'] if s['codec_type']=='audio'):
  assert audio['sample_rate']=='48000' and audio['channels']==2
  assert abs(float(audio['duration'])-61*1001/30000)<.001
assert report['silent.mp4']['video_sha256']==report['mixed.mp4']['video_sha256']
samples=array.array('h',subprocess.check_output(['ffmpeg','-v','error','-i',str(out/'mixed.mp4'),'-map','0:a:0','-f','s16le','-']))
def rms(a):return math.sqrt(sum(x*x for x in a)/len(a))
report['audio']={'start_rms':rms(samples[:14400]),'tail_rms':rms(samples[-14400:])}
assert report['audio']['tail_rms']<report['audio']['start_rms']*.3
(out/'report.json').write_text(json.dumps(report,indent=2));print(json.dumps(report,indent=2))
subprocess.run(['ffmpeg','-y','-v','error','-i',str(out/'mixed.mp4'),'-frames:v','1',str(out/'first-frame.png')],check=True)
