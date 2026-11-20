vec3 cb_post(vec3 c, vec2 uv) { return vec3(c.r, c.g, min(c.b + 0.5 * uv.y, 1.0)); }
