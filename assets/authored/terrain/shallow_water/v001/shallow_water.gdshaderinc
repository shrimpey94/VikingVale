// 2D shallow/coastal revision only. Existing IDs and authoritative geometry stay.
uniform bool shallow_enabled = false;
uniform sampler2D shallow_sand : source_color, filter_linear_mipmap, repeat_enable;
uniform sampler2D shallow_tints : filter_linear, repeat_disable;
bool sw_shallow(int b){return b==8||b==24;}
bool sw_natural_bank(int b){return (b>=0&&b<=7)||b==22||b==46;}
float sw_hash(vec2 p){return fract(sin(dot(p,vec2(127.1,311.7)))*43758.5453);}
float sw_noise(vec2 p){
 vec2 i=floor(p),f=fract(p);f=f*f*(3.0-2.0*f);
 return mix(mix(sw_hash(i),sw_hash(i+vec2(1,0)),f.x),mix(sw_hash(i+vec2(0,1)),sw_hash(i+vec2(1)),f.x),f.y);
}
vec4 shallow_surface(vec2 px,vec4 legacy){
 if(!shallow_enabled){return legacy;}
 vec2 p=px/32.0;ivec2 tile=ivec2(floor(p));int id=biome_at(tile);
 bool own=sw_shallow(id);
 bool deep=(id==9||id==57||id==58);
 if(!own&&!sw_natural_bank(id)&&!deep){return legacy;}
 // Small stationary domain warp rounds shoreline contours, never animates land.
 vec2 warp=vec2(sw_noise(p*0.7),sw_noise(p*0.7+31.0))-0.5;
 vec2 q=p+warp*0.32;
 vec2 base=floor(q-0.5),f=fract(q-0.5);f=f*f*(3.0-2.0*f);
 float water=0.0,near_shallow=0.0,deep_weight=0.0;int deep_id=9;
 for(int y=0;y<2;y++){for(int x=0;x<2;x++){
  int b=biome_at(ivec2(base)+ivec2(x,y));
  float w=(x==0?1.0-f.x:f.x)*(y==0?1.0-f.y:f.y);
  water+=w*(is_water(b)?1.0:0.0);
  near_shallow+=w*(sw_shallow(b)?1.0:0.0);
  if(b==9||b==57||b==58){deep_weight+=w;deep_id=b;}
 }}
 if(!own&&near_shallow<0.001){return legacy;}
 float bank_dist=3.0;int bank_id=22;
 bool built_edge=false;
 for(int y=-2;y<=2;y++){for(int x=-2;x<=2;x++){
  ivec2 t=tile+ivec2(x,y);int b=biome_at(t);
  float d=length(q-(vec2(t)+0.5))-0.55;
  if(!is_water(b)&&d<bank_dist){bank_dist=d;bank_id=b;}
  if(abs(x)+abs(y)==1&&!is_water(b)&&!sw_natural_bank(b)){built_edge=true;}
 }}
 float depth=smoothstep(0.05,1.9,max(bank_dist,0.0));
 vec3 sand=texture(shallow_sand,p/8.0+warp*0.015).rgb;
 // Two world-scale samples reduce obvious repetition without another map.
 sand=mix(sand,texture(shallow_sand,vec2(-p.y,p.x)/9.1+0.31).rgb,0.23);
 vec3 water_colour=mix(vec3(0.26,0.53,0.57),vec3(0.12,0.37,0.55),depth);
 sand=clamp((sand-0.5)*1.4+0.5,0.0,1.0);
 vec3 bottom=mix(sand*vec3(0.64,0.83,0.87),water_colour,mix(0.35,0.78,depth));
 bottom*=0.98+0.04*sw_noise(p*0.43);
 float edge=smoothstep(0.16,0.84,water);
 vec3 bank=sample_biome(bank_id,fract(p)*32.0).rgb;
 if(bank_id==22||bank_id==46){bank=sand;}
 // Keep man-made piers and floors crisp; soften only natural banks.
 if(built_edge||!sw_natural_bank(bank_id)){edge=own?1.0:0.0;}
 vec3 result=mix(bank,bottom,edge);
 if(!own){result=mix(legacy.rgb,bottom,edge);}
 // A narrow transition into existing deep-water art; deep interiors are untouched.
 if(deep_weight>0.0){
  vec3 deep_colour=sample_biome(deep_id,fract(p)*32.0).rgb;
  result=mix(bottom,deep_colour,deep_weight);
  if(deep){result=mix(legacy.rgb,result,smoothstep(0.0,0.25,near_shallow));}
 }
 // Preserve existing admin tint on the replacement water.
 vec2 tint=texture(shallow_tints,p/world_size_tiles).rg;
 float warm=(tint.r-0.5)*0.4,bright=(tint.g-0.5)*0.4;
 if(own){result*=vec3(1.0+warm*0.30,1.0+warm*0.05,1.0-warm*0.30)*(1.0+bright);}
 return vec4(result,legacy.a);
}
