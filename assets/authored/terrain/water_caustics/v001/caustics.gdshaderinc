// Shared world-metre coordinates and analytic animation for both renderers.
// No generated textures. Reuse the game's existing biome lookup.
uniform sampler2D water_biomes : filter_nearest, repeat_disable;
uniform vec2 water_map_size = vec2(300.0);
uniform bool caustics_enabled = false;
uniform float caustics_clock = 0.0;
uniform float caustics_strength = 0.12;
vec2 cell_hash(vec2 p) {
 return fract(sin(vec2(dot(p,vec2(127.1,311.7)),dot(p,vec2(269.5,183.3))))*43758.5453);
}
float cell_edge(vec2 p, float phase) {
 vec2 g=floor(p), f=fract(p);
 float a=9.0,b=9.0;
 for(int y=-1;y<=1;y++) {
  for(int x=-1;x<=1;x++) {
   vec2 n=vec2(float(x),float(y));
   vec2 h=cell_hash(g+n);
   vec2 point=vec2(0.5)+0.27*sin(6.2831853*h+phase);
   vec2 v=n+point-f; float d=dot(v,v);
   if(d<a){b=a;a=d;}else{b=min(b,d);}
  }
 }
 float gap=sqrt(b)-sqrt(a);
 float aa=max(fwidth(gap),0.018);
 return 1.0-smoothstep(0.035,0.035+aa,gap);
}
float water_glints(vec2 metres) {
 if(!caustics_enabled){return 0.0;}
 vec2 uv=(floor(metres)+vec2(0.5))/water_map_size;
 float id=floor(texture(water_biomes,uv).r*255.0+0.5);
 bool ocean=(id==9.0||id==57.0||id==58.0);
 bool shallow=(id==8.0||id==24.0||id==44.0||id==45.0);
 if(!ocean&&!shallow){return 0.0;} // Lava and non-water are excluded.
 float phase=6.2831853*caustics_clock/8.0;
 float drift=ocean?0.85:0.22;
 vec2 p=metres*(ocean?0.65:1.25);
 // Opposing closed drift paths give an exact eight-second review loop.
 vec2 d1=drift*vec2(cos(phase),sin(phase));
 vec2 d2=drift*vec2(sin(phase+1.7),cos(phase+1.7));
 float e1=cell_edge(p+d1,phase);
 float e2=cell_edge(p*1.13+vec2(17.3,8.9)+d2,-phase);
 return caustics_strength*(ocean?1.0:0.55)*(e1*e2+0.07*(e1+e2));
}
