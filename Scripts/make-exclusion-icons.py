#!/usr/bin/env python3
"""Build 24-point vector PDF template masks from the two active song/artist SVGs.

Uses only Python's standard library and macOS Swift/AppKit/CoreGraphics.
Original SVGs remain untouched. White ring/minus contours in exclude-song.svg
are inverse even-odd clips, making their background transparent in template tint.
The supplied white path has nested ring/minus contours compatible with that rule.
Run from any directory: python3 Scripts/make-exclusion-icons.py
"""
from pathlib import Path
import hashlib, json, math, re, subprocess, tempfile
import xml.etree.ElementTree as ET
ROOT=Path(__file__).resolve().parent.parent
ASSETS=ROOT/'Resources/MenuBarIcons'
SOURCES=ROOT/'Artwork/MenuIcons'
PREVIEW=Path('/tmp/music-filter-exclusion-icons')
PREVIEW.mkdir(parents=True,exist_ok=True)
number=r'[-+]?(?:\d*\.\d+|\d+\.?)(?:[eE][-+]?\d+)?'
command=re.compile(r'[A-Za-z]')

def cubic(a,b,c,d,t):
 u=1-t
 return u*u*u*a+3*u*u*t*b+3*u*t*t*c+t*t*t*d

def roots(a,b,c,d):
 A=-a+3*b-3*c+d;B=2*(a-2*b+c);C=b-a
 if abs(A)<1e-12:return [] if abs(B)<1e-12 else [-C/B]
 disc=B*B-4*A*C
 return [] if disc<0 else [(-B+math.sqrt(disc))/(2*A),(-B-math.sqrt(disc))/(2*A)]

def parse(d):
 tokens=re.findall(r'[MmLlHhVvCcSsQqTtAaZz]|'+number,d)
 i=0;cmd=None;current=(0.,0.);start=current;previous='';last_control=None;last_quadratic=None;segs=[];points=[]
 def read(n):
  nonlocal i
  vals=list(map(float,tokens[i:i+n]));assert len(vals)==n;i+=n;return vals
 def point(x,y,rel):return (current[0]+x,current[1]+y) if rel else (x,y)
 def line(end):
  nonlocal current
  segs.append(('L',*end));points.extend([current,end]);current=end
 def curve(c1,c2,end):
  nonlocal current,last_control
  segs.append(('C',*c1,*c2,*end));points.extend([current,end])
  for axis in [0,1]:
   for t in roots(current[axis],c1[axis],c2[axis],end[axis]):
    if 0<t<1:points.append(tuple(cubic(current[k],c1[k],c2[k],end[k],t) for k in [0,1]))
  current=end;last_control=c2
 def quadratic(control,end):
  nonlocal last_quadratic
  c1=tuple(current[k]+2*(control[k]-current[k])/3 for k in [0,1])
  c2=tuple(end[k]+2*(control[k]-end[k])/3 for k in [0,1])
  curve(c1,c2,end);last_quadratic=control
 while i<len(tokens):
  if command.fullmatch(tokens[i]):cmd=tokens[i];i+=1
  assert cmd is not None
  kind=cmd.upper();rel=cmd.islower()
  if kind=='M':
   x,y=read(2);current=point(x,y,rel);start=current;segs.append(('M',*current));points.append(current);previous='M';last_control=None;last_quadratic=None;cmd='l' if rel else 'L';continue
  if kind=='L':
   x,y=read(2);line(point(x,y,rel));last_control=None
  elif kind=='H':
   x=read(1)[0];line((current[0]+x if rel else x,current[1]));last_control=None
  elif kind=='V':
   y=read(1)[0];line((current[0],current[1]+y if rel else y));last_control=None
  elif kind=='C':
   a,b,c,d,e,f=read(6);curve(point(a,b,rel),point(c,d,rel),point(e,f,rel))
  elif kind=='S':
   a,b,c,d=read(4);c1=(2*current[0]-last_control[0],2*current[1]-last_control[1]) if previous in ['C','S'] and last_control else current
   curve(c1,point(a,b,rel),point(c,d,rel))
  elif kind=='Q':
   a,b,c,d=read(4);quadratic(point(a,b,rel),point(c,d,rel))
  elif kind=='T':
   a,b=read(2);control=(2*current[0]-last_quadratic[0],2*current[1]-last_quadratic[1]) if previous in ['Q','T'] and last_quadratic else current
   quadratic(control,point(a,b,rel))
  elif kind=='Z':
   segs.append(('Z',));points.extend([current,start]);current=start;last_control=None;last_quadratic=None;cmd=None
  else:raise ValueError('Unsupported SVG command '+kind)
  previous=kind
 return segs,points


def shapes_for(source):
    root=ET.fromstring(source.read_bytes())
    assert root.attrib.get('viewBox') == '0 0 24 24', 'Expected exact 24-point source'
    styles={}
    for node in root.iter():
        if node.tag.endswith('style'):
            for name,body in re.findall(r'\.([\w-]+)\s*\{([^}]+)\}',node.text or ''):
                styles[name]={k.strip():v.strip() for k,v in (part.split(':',1) for part in body.split(';') if ':' in part)}
    shapes=[]
    def visit(node,inherited=None):
        tag=node.tag.rsplit('}',1)[-1]
        if tag in ['defs','style','title','desc']:return
        assert 'transform' not in node.attrib, 'Unsupported transform must not be silently dropped'
        props=dict(inherited or {})
        for classname in node.attrib.get('class','').split():props.update(styles.get(classname,{}))
        props.update({k:v for k,v in node.attrib.items() if k in ['fill','fill-rule','stroke','stroke-width','stroke-linecap','stroke-linejoin','opacity','fill-opacity']})
        assert float(props.get('opacity','1'))==1 and float(props.get('fill-opacity','1'))==1
        if tag in ['svg','g']:
            for child in node:visit(child,props)
            return
        fill=props.get('fill','#000').lower()
        assert fill in ['black','#000','#000000','white','#fff','#ffffff','none']
        stroke=props.get('stroke','none').lower()
        assert stroke in ['none','black','#000','#000000']
        shape={'kind':tag,'fill':'white' if fill in ['white','#fff','#ffffff'] else ('none' if fill=='none' else 'black'),
               'evenOdd':props.get('fill-rule','nonzero')=='evenodd','stroke':0 if stroke=='none' else float(props.get('stroke-width','1').removesuffix('px')),
               'roundCap':props.get('stroke-linecap')=='round','roundJoin':props.get('stroke-linejoin')=='round'}
        if tag=='path':shape['segments']=parse(node.attrib['d'])[0]
        elif tag=='circle':shape.update({k:float(node.attrib[k]) for k in ['cx','cy','r']})
        elif tag=='rect':shape.update({k:float(node.attrib.get(k,'0')) for k in ['x','y','width','height','rx','ry']})
        else:raise ValueError('Unsupported SVG shape '+tag)
        shapes.append(shape)
    visit(root)
    return shapes

SWIFT=r'''
import AppKit
import Foundation
let data=try Data(contentsOf:URL(fileURLWithPath:CommandLine.arguments[1]))
let input=try JSONSerialization.jsonObject(with:data) as! [String:Any]
let assets=URL(fileURLWithPath:input["assets"] as! String)
let output=URL(fileURLWithPath:input["preview"] as! String)
let files=input["files"] as! [[String:Any]]
func path(_ object:[String:Any])->CGPath {
 let p=CGMutablePath()
 func n(_ key:String)->CGFloat {CGFloat((object[key] as! NSNumber).doubleValue)}
 switch object["kind"] as! String {
 case "path":
  for segment in object["segments"] as! [[Any]] {
   func point(_ i:Int)->CGPoint {CGPoint(x:(segment[i] as! NSNumber).doubleValue,y:(segment[i+1] as! NSNumber).doubleValue)}
   switch segment[0] as! String {
   case "M":p.move(to:point(1))
   case "L":p.addLine(to:point(1))
   case "C":p.addCurve(to:point(5),control1:point(1),control2:point(3))
   case "Z":p.closeSubpath()
   default:fatalError("Unsupported path segment")
   }
  }
 case "circle":p.addEllipse(in:CGRect(x:n("cx")-n("r"),y:n("cy")-n("r"),width:2*n("r"),height:2*n("r")))
 case "rect":p.addRoundedRect(in:CGRect(x:n("x"),y:n("y"),width:n("width"),height:n("height")),cornerWidth:n("rx"),cornerHeight:n("ry"))
 default:fatalError("Unsupported shape")
 }
 return p
}
func draw(_ shapes:[[String:Any]],in context:CGContext,knockout:Bool) {
 for (index,shape) in shapes.enumerated() {
  let fill=shape["fill"] as! String
  if knockout && fill=="white" {continue}
  context.saveGState()
  if knockout {
   for white in shapes.dropFirst(index+1) where white["fill"] as? String == "white" {
    // Subtract only later white paint, preserving the SVG painter's order.
    // The supplied white compound path consists of a ring and a minus.
    let inverse=CGMutablePath();inverse.addRect(CGRect(x:0,y:0,width:24,height:24));inverse.addPath(path(white))
    context.addPath(inverse);context.clip(using:.evenOdd)
   }
  }
  if fill != "none" {
   context.setFillColor(gray:fill=="white" ? 1:0,alpha:1)
   context.addPath(path(shape));context.fillPath(using:(shape["evenOdd"] as! Bool) ? .evenOdd:.winding)
  }
  let stroke=(shape["stroke"] as! NSNumber).doubleValue
  if stroke>0 {
   context.setStrokeColor(gray:0,alpha:1);context.setLineWidth(stroke)
   context.setLineCap((shape["roundCap"] as! Bool) ? .round:.butt)
   context.setLineJoin((shape["roundJoin"] as! Bool) ? .round:.miter)
   context.addPath(path(shape));context.strokePath()
  }
  context.restoreGState()
 }
}
func bitmap(_ width:Int,_ height:Int)->NSBitmapImageRep {
 NSBitmapImageRep(bitmapDataPlanes:nil,pixelsWide:width,pixelsHigh:height,bitsPerSample:8,samplesPerPixel:4,hasAlpha:true,isPlanar:false,colorSpaceName:.deviceRGB,bytesPerRow:0,bitsPerPixel:0)!
}
func png(_ bitmap:NSBitmapImageRep,_ name:String) throws {
 try bitmap.representation(using:.png,properties:[:])!.write(to:output.appendingPathComponent(name))
}
for file in files {
 let name=file["name"] as! String;let shapes=file["shapes"] as! [[String:Any]]
 var box=CGRect(x:0,y:0,width:24,height:24)
 let pdf=CGContext(assets.appendingPathComponent(name+".pdf") as CFURL,mediaBox:&box,nil)!
 pdf.beginPDFPage(nil);pdf.translateBy(x:0,y:24);pdf.scaleBy(x:1,y:-1)
 draw(shapes,in:pdf,knockout:true);pdf.endPDFPage();pdf.closePDF()
 let doc=CGPDFDocument(assets.appendingPathComponent(name+".pdf") as CFURL)!
 precondition(doc.numberOfPages==1 && doc.page(at:1)!.getBoxRect(.mediaBox)==box)
 // Reference SVG paint on white for checking exact visible geometry.
 let reference=bitmap(1536,1536);let cg=NSGraphicsContext(bitmapImageRep:reference)!.cgContext
 cg.setFillColor(gray:1,alpha:1);cg.fill(CGRect(x:0,y:0,width:1536,height:1536))
 cg.translateBy(x:0,y:1536);cg.scaleBy(x:64,y:-64);draw(shapes,in:cg,knockout:false)
 try png(reference,"source-"+name+".png")
 // PDF raster on white for a faithful native vector round-trip comparison.
 let roundtrip=bitmap(1536,1536);let pg=NSGraphicsContext(bitmapImageRep:roundtrip)!.cgContext
 pg.setFillColor(gray:1,alpha:1);pg.fill(CGRect(x:0,y:0,width:1536,height:1536));pg.scaleBy(x:64,y:64);pg.drawPDFPage(doc.page(at:1)!)
 try png(roundtrip,"pdf-"+name+".png")
 print(name+".pdf: vector 24×24")
}
// Same isolated transparency/sourceIn tint operation as the production menu.
let preview=bitmap(1320,640);let graphics=NSGraphicsContext(bitmapImageRep:preview)!
NSGraphicsContext.saveGraphicsState();NSGraphicsContext.current=graphics
let cg=graphics.cgContext;cg.scaleBy(x:2,y:2)
for (row,dark) in [false,true].enumerated() {
 let bottom=CGFloat(1-row)*160
 let background=dark ? NSColor(calibratedWhite:0.13,alpha:1):.white
 let ink=dark ? NSColor.white:NSColor.black
 background.setFill();NSRect(x:0,y:bottom,width:660,height:160).fill()
 for (column,file) in files.enumerated() {
  let x=CGFloat(column)*220;let name=file["name"] as! String
  let image=NSImage(contentsOf:assets.appendingPathComponent(name+".pdf"))!;image.isTemplate=true
  image.size=NSSize(width:14,height:14)
  let label=(file["label"] as! String)+(dark ? " — sombre":" — clair")
  (label as NSString).draw(at:NSPoint(x:x+16,y:bottom+134),withAttributes:[.font:NSFont.systemFont(ofSize:12),.foregroundColor:ink])
  for (size,origin) in [(CGFloat(14),NSPoint(x:x+32,y:bottom+70)),(CGFloat(88),NSPoint(x:x+110,y:bottom+35))] {
   cg.saveGState();cg.beginTransparencyLayer(auxiliaryInfo:nil)
   let rect=NSRect(origin:origin,size:NSSize(width:size,height:size))
   image.draw(in:rect)
   cg.setBlendMode(.sourceIn);ink.setFill();rect.fill()
   cg.endTransparencyLayer();cg.restoreGState()
  }
  ("14 pt       ×6,3" as NSString).draw(at:NSPoint(x:x+24,y:bottom+14),withAttributes:[.font:NSFont.systemFont(ofSize:11),.foregroundColor:ink.withAlphaComponent(0.65)])
 }
}
NSGraphicsContext.restoreGraphicsState();try png(preview,"comparison.png")
'''

files=[]
for name,label in [('exclude-song','Morceau'),('exclude-artist','Artiste')]:
    source=SOURCES/(name+'.svg')
    files.append({'name':name,'label':label,'shapes':shapes_for(source)})
    print(name+'.svg SHA256 '+hashlib.sha256(source.read_bytes()).hexdigest(),flush=True)
with tempfile.TemporaryDirectory(prefix='music-filter-vector-icons-') as folder:
    folder=Path(folder)
    (folder/'render.swift').write_text(SWIFT)
    (folder/'input.json').write_text(json.dumps({'assets':str(ASSETS),'preview':str(PREVIEW),'files':files}))
    subprocess.run(['swift',str(folder/'render.swift'),str(folder/'input.json')],check=True)
for file in files:
    pdf=ASSETS/(file['name']+'.pdf')
    assert b'/Subtype /Image' not in pdf.read_bytes(),'Unexpected raster PDF resource'
print('Preview: '+str(PREVIEW/'comparison.png'))
