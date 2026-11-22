// Both modes sample the same final smoothed corner elevations in metres.
uniform bool height_colors_enabled = false;
uniform sampler2D terrain_height_corners : filter_linear, repeat_disable;
uniform vec2 terrain_height_grid_size = vec2(301.0);
uniform float rock_height_start = 3.0;
uniform float rock_height_full = 13.0;
uniform float snow_height_start = 12.0;
uniform float snow_height_full = 20.0;
float height_rock_weight(float h){return smoothstep(rock_height_start,rock_height_full,h);}
float height_snow_weight(float h){return smoothstep(snow_height_start,snow_height_full,h);}
vec3 natural_elevation_colour(vec3 base,vec2 p){
 if(!height_colors_enabled || any(lessThan(p,vec2(0.0))) || any(greaterThan(p,terrain_height_grid_size-1.0)))return base;
 float h=texture(terrain_height_corners,(p+.5)/terrain_height_grid_size).r;
 float r=height_rock_weight(h);
 vec3 stone=mix(texture(mountain_albedo,p/4.0).rgb,texture(cliff_albedo,p/5.7).rgb,.28)*vec3(.94,.98,1.04);
 vec3 result=mix(base,stone,r);
 // Snow is inappropriate in volcanic/Helheim ground; soften this allowance at biome edges.
 vec2 cell=floor(p);float cold=0.0;float total=0.0;
 for(int y=-1;y<=1;y++){for(int x=-1;x<=1;x++){
  vec2 at=cell+vec2(float(x),float(y));int k=material_index(sample_id(at));
  float w=exp(-dot(at+.5-p,at+.5-p)*2.5);total+=w;
  if(k!=5 && k!=6 && k!=7 && k!=13)cold+=w;
 }}
 float snow=height_snow_weight(h)*cold/max(total,.0001);
 return mix(result,texture(snow_albedo,p/4.0).rgb,snow);
}

// Built surface colour shifts only; keep joint/gravel/weave luminance and texture.
uniform float built_height_tint_strength : hint_range(0.0,0.35) = 0.30;
bool is_built_surface(float id){
 return id==13.0||id==14.0||id==16.0||id==17.0||id==18.0||id==19.0||id==20.0||id==21.0||id==23.0||id==48.0||id==49.0||id==84.0||id==85.0||id==86.0;
}
vec3 elevation_colour(vec3 base,vec2 p){
 if(!is_built_surface(sample_id(floor(p))))return natural_elevation_colour(base,p);
 if(!height_colors_enabled||any(lessThan(p,vec2(0.0)))||any(greaterThan(p,terrain_height_grid_size-1.0)))return base;
 float h=texture(terrain_height_corners,(p+.5)/terrain_height_grid_size).r;
 float luminance=dot(base,vec3(.2126,.7152,.0722));
 vec3 cool=luminance*vec3(.90,.97,1.08);
 return mix(base,cool,clamp(built_height_tint_strength,0.0,.35)*height_rock_weight(h));
}
