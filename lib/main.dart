import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

void main() => runApp(const ModelSplitterApp());

class ModelSplitterApp extends StatelessWidget {
  const ModelSplitterApp({super.key});
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Model Splitter',
      theme: ThemeData.dark(useMaterial3: true),
      home: const HomePage(),
    );
  }
}

class Vec3 {
  final double x, y, z;
  const Vec3(this.x, this.y, this.z);
  Vec3 operator -(Vec3 o) => Vec3(x - o.x, y - o.y, z - o.z);
  Vec3 cross(Vec3 o) => Vec3(y*o.z-z*o.y, z*o.x-x*o.z, x*o.y-y*o.x);
  double length() => math.sqrt(x*x+y*y+z*z);
  Vec3 normalized() { final l=length(); return l==0?this:Vec3(x/l,y/l,z/l); }
}

class Triangle {
  final Vec3 a,b,c;
  const Triangle(this.a,this.b,this.c);
}

class Mesh {
  final List<Triangle> triangles;
  Mesh(this.triangles);

  static Mesh parseSTL(String content) {
    final t = content.trimLeft().toLowerCase();
    if (t.startsWith('solid')) return _ascii(content);
    return _binary(content);
  }

  static Mesh _ascii(String s) {
    final tris=<Triangle>[]; final vs=<Vec3>[];
    for (final line in s.split(RegExp(r'\r?\n'))) {
      final p=line.trim().split(RegExp(r'\s+'));
      if (p.length>=4 && p[0]=='vertex') {
        vs.add(Vec3(double.parse(p[1]),double.parse(p[2]),double.parse(p[3])));
        if (vs.length==3) { tris.add(Triangle(vs[0],vs[1],vs[2])); vs.clear(); }
      }
    }
    return Mesh(tris);
  }

  static Mesh _binary(String s) {
    final bytes=Uint8List.fromList(s.codeUnits);
    final d=ByteData.sublistView(bytes);
    final count=d.getUint32(80,Endian.little);
    final tris=<Triangle>[]; var o=84;
    for (var i=0;i<count;i++) {
      o+=12;
      final a=_v(d,o), b=_v(d,o+12), c=_v(d,o+24);
      tris.add(Triangle(a,b,c));
      o+=38;
    }
    return Mesh(tris);
  }

  static Vec3 _v(ByteData d,int o)=>Vec3(d.getFloat32(o,Endian.little),d.getFloat32(o+4,Endian.little),d.getFloat32(o+8,Endian.little));

  String toSTL() {
    final b=StringBuffer('solid model\n');
    for (final t in triangles) {
      final n=(t.b-t.a).cross(t.c-t.a).normalized();
      b.writeln(' facet normal ${n.x} ${n.y} ${n.z}');
      b.writeln('  outer loop');
      for (final v in [t.a,t.b,t.c]) b.writeln('   vertex ${v.x} ${v.y} ${v.z}');
      b.writeln('  endloop\n endfacet');
    }
    b.writeln('endsolid model');
    return b.toString();
  }
}

class HomePage extends StatefulWidget {
  const HomePage({super.key});
  @override
  State<HomePage> createState()=>_HomePageState();
}

class _HomePageState extends State<HomePage> {
  Mesh? model, pieceA, pieceB;
  String axis='z';
  double position=0, rotationY=0;
  bool busy=false;
  String status='Importă un fișier STL.';

  Future<void> importSTL() async {
    final r=await FilePicker.platform.pickFiles(type: FileType.any);
    final path=r?.files.single.path;
    if(path==null) return;
    setState(()=>{busy=true,status='Se încarcă modelul...'});
    try {
      final mesh=Mesh.parseSTL(await File(path).readAsString());
      setState(()=>{model=mesh,pieceA=null,pieceB=null,position=_center(mesh,axis),status='Model încărcat: ${mesh.triangles.length} triunghiuri.'});
    } catch(e){ setState(()=>status='Eroare: $e'); }
    finally{ setState(()=>busy=false); }
  }

  double _center(Mesh m,String ax){
    double mn=double.infinity,mx=-double.infinity;
    for(final t in m.triangles) for(final v in [t.a,t.b,t.c]){
      final val=ax=='x'?v.x:ax=='y'?v.y:v.z;
      if(val<mn)mn=val; if(val>mx)mx=val;
    }
    return (mn+mx)/2;
  }

  void cutModel(){
    final m=model; if(m==null)return;
    final a=<Triangle>[],b=<Triangle>[];
    for(final t in m.triangles){
      final vals=[t.a,t.b,t.c].map((v)=>axis=='x'?v.x:axis=='y'?v.y:v.z).toList();
      if(vals.every((v)=>v>=position)) a.add(t);
      else if(vals.every((v)=>v<=position)) b.add(t);
      else { a.add(t); b.add(t); }
    }
    setState(()=>{pieceA=Mesh(a),pieceB=Mesh(b),status='Tăiere finalizată.'});
  }

  Future<void> exportPiece(Mesh? mesh,String name) async {
    if(mesh==null)return;
    final dir=await getTemporaryDirectory();
    final f=File('${dir.path}/$name');
    await f.writeAsString(mesh.toSTL());
    await Share.shareXFiles([XFile(f.path)],text:name);
  }

  @override
  Widget build(BuildContext context){
    final mesh=pieceA??pieceB??model;
    return Scaffold(
      appBar:AppBar(title:const Text('Model Splitter')),
      body:Column(children:[
        Expanded(child:GestureDetector(
          onHorizontalDragUpdate:(d)=>setState(()=>rotationY+=d.delta.dx*0.01),
          child:CustomPaint(painter:MeshPainter(mesh:mesh,rotationY:rotationY,axis:axis,cutPosition:position),child:Container()),
        )),
        Container(
          padding:const EdgeInsets.all(16),
          color:const Color(0xFF171A21),
          child:Column(children:[
            Text(status,style:const TextStyle(fontSize:12,color:Colors.white70)),
            const SizedBox(height:12),
            FilledButton.icon(onPressed:busy?null:importSTL,icon:const Icon(Icons.upload_file),label:const Text('Import STL')),
            const SizedBox(height:12),
            SegmentedButton<String>(
              segments:const [ButtonSegment(value:'x',label:Text('X')),ButtonSegment(value:'y',label:Text('Y')),ButtonSegment(value:'z',label:Text('Z'))],
              selected:{axis},
              onSelectionChanged:(v)=>setState(()=>{axis=v.first; if(model!=null)position=_center(model!,axis);}),
            ),
            Slider(value:position,onChanged:model==null?null:(v)=>setState(()=>position=v)),
            FilledButton(onPressed:model==null?null:cutModel,child:const Text('Taie modelul')),
            const SizedBox(height:8),
            Row(children:[
              Expanded(child:OutlinedButton(onPressed:pieceA==null?null:()=>exportPiece(pieceA,'piesa-A.stl'),child:const Text('Export A'))),
              const SizedBox(width:8),
              Expanded(child:OutlinedButton(onPressed:pieceB==null?null:()=>exportPiece(pieceB,'piesa-B.stl'),child:const Text('Export B'))),
            ]),
          ]),
        ),
      ]),
    );
  }
}

class MeshPainter extends CustomPainter {
  final Mesh? mesh; final double rotationY; final String axis; final double cutPosition;
  MeshPainter({required this.mesh,required this.rotationY,required this.axis,required this.cutPosition});

  @override
  void paint(Canvas canvas,Size size){
    if(mesh==null)return;
    final paint=Paint()..color=const Color(0xFF8AB4F8)..style=PaintingStyle.stroke..strokeWidth=0.7;
    final cut=Paint()..color=const Color(0xFF4C9AFF)..strokeWidth=2;
    final scale=size.shortestSide/220;
    final center=Offset(size.width/2,size.height/2);

    for(final t in mesh!.triangles){
      final pts=<Offset>[];
      for(final v in [t.a,t.b,t.c]){
        final cos=math.cos(rotationY),sin=math.sin(rotationY);
        final x=v.x*cos-v.z*sin;
        pts.add(Offset(center.dx+x*scale,center.dy-v.y*scale));
      }
      canvas.drawPath(Path()..addPolygon(pts,true),paint);
    }

    final p1=axis=='x'?Vec3(cutPosition,-100,0):axis=='y'?Vec3(0,cutPosition,0):Vec3(-100,0,cutPosition);
    final p2=axis=='x'?Vec3(cutPosition,100,0):axis=='y'?Vec3(0,cutPosition,0):Vec3(100,0,cutPosition);
    canvas.drawLine(_proj(p1,scale,center),_proj(p2,scale,center),cut);
  }

  Offset _proj(Vec3 v,double s,Offset c){
    final cos=math.cos(rotationY),sin=math.sin(rotationY);
    final x=v.x*cos-v.z*sin;
    return Offset(c.dx+x*s,c.dy-v.y*s);
  }

  @override
  bool shouldRepaint(covariant MeshPainter old)=>true;
}
