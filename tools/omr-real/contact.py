import sys,glob,json
from PIL import Image, ImageDraw
d,out,a,b=sys.argv[1],sys.argv[2],int(sys.argv[3]),int(sys.argv[4])
ids=['real-%03d'%i for i in range(a,b)]
W,H=300,420; cols=6; rows=(len(ids)+cols-1)//cols
sh=Image.new('RGB',(W*cols,H*rows),'white'); dr=ImageDraw.Draw(sh)
for k,i in enumerate(ids):
    f=glob.glob(f'{d}/{i}.png')+glob.glob(f'{d}/{i}.jpg')
    im=Image.open(f[0]).convert('RGB'); im.thumbnail((W-6,H-20))
    x,y=(k%cols)*W,(k//cols)*H; sh.paste(im,(x+3,y+16)); dr.text((x+4,y+2),i,fill='red')
sh.save(out)
