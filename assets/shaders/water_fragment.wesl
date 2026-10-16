import bevy_pbr::render::{
  pbr_functions::alpha_discard,
  pbr_fragment::pbr_input_from_standard_material,
  view_transformations::depth_ndc_to_view_z,
};

@if(PREPASS_PIPELINE)
import bevy_pbr::{
  prepass::io::{VertexOutput, FragmentOutput},
  deferred::functions::deferred_output,
};
@else
import bevy_pbr::render::{
  forward_io::{VertexOutput, FragmentOutput},
  pbr_functions::{apply_pbr_lighting, main_pass_post_lighting_processing},
  pbr_types::STANDARD_MATERIAL_FLAGS_UNLIT_BIT,
};

@if(VISIBILITY_RANGE_DITHER)
import bevy_pbr::render::pbr_functions::visibility_range_dither;

@if(MESHLET_MESH_MATERIAL_PASS)
import bevy_pbr::meshlet::visibility_buffer_resolve::resolve_vertex_output;

@if(!SHORE_MAP && DEPTH_PREPASS && !PREPASS_PIPELINE && !WEBGL2)
import bevy_pbr::prepass::utils::prepass_depth;

import package::water_bindings;
import package::water_functions as water_fn;

@fragment
fn fragment(
@if(MESHLET_MESH_MATERIAL_PASS)
  @builtin(position) frag_coord: vec4<f32>,
@if(!MESHLET_MESH_MATERIAL_PASS)
  p_in: VertexOutput,
@if(!MESHLET_MESH_MATERIAL_PASS)
  @builtin(front_facing) is_front: bool,
) -> FragmentOutput {
@if(MESHLET_MESH_MATERIAL_PASS)
  let p_in = resolve_vertex_output(frag_coord);
@if(MESHLET_MESH_MATERIAL_PASS)
  let is_front = true;

  var in = p_in;
  var world_position: vec4<f32> = in.world_position;
  let w_pos = water_fn::uv_to_coord(in.uv);
  // Calculate normal.
  let height = water_fn::get_wave_height(w_pos);
  // `QUALITY` is an integer def; see water_functions for why this is an `if`.
  if constants::QUALITY > 2 {
    let delta = 0.5;
    let height_dx = water_fn::get_wave_height(w_pos + vec2<f32>(delta, 0.0));
    let height_dz = water_fn::get_wave_height(w_pos + vec2<f32>(0.0, delta));
    in.world_normal = normalize(vec3<f32>(height - height_dx, delta, height - height_dz));
  } else {
    let pos = world_position.xyz + (in.world_normal * height);
    let pos_dx = dpdx(pos);
    let pos_dy = dpdy(pos);
    in.world_normal = normalize(cross(pos_dy, pos_dx));
  }

  // If we're in the crossfade section of a visibility range, conditionally
  // discard the fragment according to the visibility pattern.
@if(VISIBILITY_RANGE_DITHER)
  visibility_range_dither(in.position, in.visibility_range_dither);

  // generate a PbrInput struct from the StandardMaterial bindings
  var pbr_input = pbr_input_from_standard_material(in, is_front);

  let deep_color = water_bindings::material.deep_color;
  var water_color = deep_color;
@if(SHORE_MAP) {
    // The same Beer's-law and edge mix as the depth-prepass path below, with
    // the distance to the shore standing in for the depth of the water.
    let rect = water_bindings::material.shore_rect;
    let uv = (w_pos - rect.xy) / rect.zw;
    // Past the mapped rect the water only gets further from the shore.
    let outside = length(max(max(rect.xy - w_pos, w_pos - (rect.xy + rect.zw)), vec2<f32>(0.0)));
    let mapped = textureSampleLevel(water_bindings::shore_map, water_bindings::shore_sampler, uv, 0.0).r;
    let shore_dist = mapped * water_bindings::material.shore_range + outside;

    let beers_law = exp(-shore_dist * water_bindings::material.clarity);
    let depth_color = vec4<f32>(
      mix(deep_color.xyz, water_bindings::material.shallow_color.xyz, beers_law),
      1.0,
    );
    // The edge band breathes with the swell: a crest reaches further up the
    // beach than a trough, so its foam stands further out.
    let swell = clamp(height / max(water_bindings::material.amplitude, 1e-4), -1.0, 0.5);
    let edge_scale = max(water_bindings::material.edge_scale * (1.0 + 0.6 * swell), 1e-3);
    water_color = mix(water_bindings::material.edge_color, depth_color, smoothstep(0.0, edge_scale, shore_dist));
}
@if(!SHORE_MAP && DEPTH_PREPASS && !PREPASS_PIPELINE && !WEBGL2) {
    let water_clarity = water_bindings::material.clarity;
    let shallow_color = water_bindings::material.shallow_color;
    let edge_scale = water_bindings::material.edge_scale;
    let edge_color = water_bindings::material.edge_color;

    let z_depth_buffer_ndc = prepass_depth(in.position, 0u);
    let z_depth_buffer_view = depth_ndc_to_view_z(z_depth_buffer_ndc);
    let z_fragment_view = depth_ndc_to_view_z(in.position.z);
    let depth_diff_view = z_fragment_view - z_depth_buffer_view;
    let beers_law = exp(-depth_diff_view * water_clarity);
    let depth_color = vec4<f32>(mix(deep_color.xyz, shallow_color.xyz, beers_law), 1.0 - beers_law);
    water_color = mix(edge_color, depth_color, smoothstep(0.0, edge_scale, depth_diff_view));
}
  pbr_input.material.base_color *= water_color;

  // alpha discard
  pbr_input.material.base_color = alpha_discard(
    pbr_input.material.flags,
    pbr_input.material.alpha_cutoff,
    pbr_input.material.base_color
  );

  // write the gbuffer, lighting pass id, and optionally normal and motion_vector textures
@if(PREPASS_PIPELINE)
  let out = deferred_output(in, pbr_input);
  // in forward mode, we calculate the lit color immediately, and then apply some post-lighting effects here.
  // in deferred mode the lit color and these effects will be calculated in the deferred lighting shader
@if(!PREPASS_PIPELINE)
  var out: FragmentOutput;
@if(!PREPASS_PIPELINE)
  if (pbr_input.material.flags & STANDARD_MATERIAL_FLAGS_UNLIT_BIT) == 0u {
    out.color = apply_pbr_lighting(pbr_input);
  } else {
    out.color = pbr_input.material.base_color;
  }

  // apply in-shader post processing (fog, alpha-premultiply, and also tonemapping, debanding if the camera is non-hdr)
  // note this does not include fullscreen postprocessing effects like bloom.
@if(!PREPASS_PIPELINE)
  out.color = main_pass_post_lighting_processing(pbr_input, out.color);

  return out;
}
