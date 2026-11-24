uniform sampler2D ocean_biomes : filter_nearest,repeat_disable;
uniform vec2 ocean_map_size=vec2(300.0,520.0);
uniform sampler2D kelp_fronds : source_color,filter_linear_mipmap,repeat_enable;
uniform bool ocean_enabled=false;
uniform float ocean_clock=0.0;
float ocean_id(vec2 p){return floor(texture(ocean_biomes,(p+0.5)/ocean_map_size).r*255.0+0.5);}
float ocean_noise(vec2 p){
 vec2 i=floor(p),f=fract(p);f=f*f*(3.0-2.0*f);
 float a=fract(sin(dot(i,vec2(127.1,311.7)))*43758.5453);
 float b=fract(sin(dot(i+vec2(1,0),vec2(127.1,311.7)))*43758.5453);
 float c=fract(sin(dot(i+vec2(0,1),vec2(127.1,311.7)))*43758.5453);
 float d=fract(sin(dot(i+vec2(1),vec2(127.1,311.7)))*43758.5453);
 return mix(mix(a,b,f.x),mix(c,d,f.x),f.y);
}
void ocean_surface(vec2 p,out vec3 pigment,out float coverage,out float opacity){
 pigment=vec3(0);coverage=0.0;opacity=0.66;
 if(ocean_enabled){
  vec2 base=floor(p-0.5),f=smoothstep(0.0,1.0,fract(p-0.5));float wk=0.0,wd=0.0;
  for(int y=0;y<2;y++){for(int x=0;x<2;x++){
   float id=ocean_id(base+vec2(float(x),float(y)));float w=(x==0?1.0-f.x:f.x)*(y==0?1.0-f.y:f.y);
   wk+=w*(id==57.0?1.0:0.0);wd+=w*(id==58.0?1.0:0.0);
  }}
  coverage=wk+wd;
  if(coverage>0.001){
   float absorption=ocean_noise(p*0.17);
   vec3 deep=mix(vec3(0.035,0.115,0.235),vec3(0.055,0.18,0.29),absorption);
   vec3 water=mix(vec3(0.10,0.29,0.34),vec3(0.13,0.36,0.40),absorption);
   float phase=6.2831853*ocean_clock/8.0;
   vec2 uv=p/6.0+vec2(sin(phase+p.y*0.6),cos(phase+p.x*0.4))*0.012;
   vec4 leaf=texture(kelp_fronds,uv);
   vec3 submerged=mix(leaf.rgb,vec3(0.08,0.34,0.32),0.35);
   vec3 kelp=mix(water,submerged,leaf.a*0.80);
   pigment=(kelp*wk+deep*wd)/coverage;
   opacity=(0.80*wk+0.91*wd)/coverage;
  }
 }
}
vec4 ocean_colour_2d(vec2 p,vec4 existing){
 vec3 c;float w;float a;ocean_surface(p,c,w,a);return vec4(mix(existing.rgb,c,w),existing.a);
}
