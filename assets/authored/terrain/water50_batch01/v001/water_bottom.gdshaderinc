uniform sampler2D bottom_biomes : filter_nearest, repeat_disable;
uniform vec2 bottom_map_size = vec2(300.0);
uniform bool bottom_enabled = false;
uniform sampler2D reef_albedo : source_color,filter_linear_mipmap,repeat_enable;
uniform sampler2D reef_normal : filter_linear_mipmap,repeat_enable;
uniform sampler2D reef_params : filter_linear_mipmap,repeat_enable;
uniform sampler2D tidepool_albedo : source_color,filter_linear_mipmap,repeat_enable;
uniform sampler2D tidepool_normal : filter_linear_mipmap,repeat_enable;
uniform sampler2D tidepool_params : filter_linear_mipmap,repeat_enable;
float bottom_id(vec2 cell){return floor(texture(bottom_biomes,(cell+0.5)/bottom_map_size).r*255.0+0.5);}
void bottom_material(vec2 p,out vec3 colour,out vec3 normal,out vec3 params,out float coverage){
 colour=vec3(0);normal=vec3(0,0,1);params=vec3(0.5,0,0);coverage=0.0;
 if(bottom_enabled){
  vec2 b=floor(p-0.5),f=smoothstep(0.0,1.0,fract(p-0.5));
  vec3 c=vec3(0),n=vec3(0),m=vec3(0);
  for(int y=0;y<2;y++){for(int x=0;x<2;x++){
   float id=bottom_id(b+vec2(float(x),float(y)));
   float w=(x==0?1.0-f.x:f.x)*(y==0?1.0-f.y:f.y);
   vec2 uv=p/4.0;
   if(id==44.0){c+=texture(reef_albedo,uv).rgb*w;n+=(texture(reef_normal,uv).rgb*2.0-1.0)*w;m+=texture(reef_params,uv).rgb*w;coverage+=w;}
   if(id==45.0){c+=texture(tidepool_albedo,uv).rgb*w;n+=(texture(tidepool_normal,uv).rgb*2.0-1.0)*w;m+=texture(tidepool_params,uv).rgb*w;coverage+=w;}
  }}
  if(coverage>0.001){colour=c/coverage;normal=normalize(n);params=m/coverage;}
 }
}
// 2D water absorption only, no painted/directional lighting or drop shadows.
vec4 bottom_colour_2d(vec2 metres,vec4 existing){
 vec3 c;vec3 n;vec3 p;float w;bottom_material(metres,c,n,p,w);
 c=mix(c,vec3(0.16,0.57,0.70),p.b*0.65);
 return vec4(mix(existing.rgb,c,w),existing.a);
}
