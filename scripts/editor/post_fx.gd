class_name PostFx
## The Environment's post effects (vignette, scanlines, grain, posterize, bloom, curve, outline, dither) as a preview in the editor's
## screens: a ColorRect laid over the view whose shader redraws what is under it, the way the program's
## post shader (cb_be_raylib.c) does. Shown only while an effect is on.

const SHADER := """shader_type canvas_item;
uniform sampler2D screen_tex : hint_screen_texture, filter_nearest, repeat_disable;
uniform vec4 fx = vec4(0.0);
uniform vec4 fx2 = vec4(0.0);
uniform vec2 origin = vec2(0.0);
uniform vec2 extent = vec2(1.0);
vec3 src(vec2 sp, vec2 uv) {
	return texture(screen_tex, (uv * extent + origin) * sp).rgb;
}
float luma(vec3 c) {
	return dot(c, vec3(0.299, 0.587, 0.114));
}
float b2(float a, float b) {
	return mod(2.0 * a + 3.0 * b, 4.0);
}
void fragment() {
	vec2 sp = SCREEN_PIXEL_SIZE;
	vec2 uv = (FRAGCOORD.xy - origin) / extent;
	bool outside = false;
	if (fx2.y > 0.0) {
		vec2 w = uv * 2.0 - 1.0;
		w *= vec2(1.0 + w.y * w.y * fx2.y * 0.25, 1.0 + w.x * w.x * fx2.y * 0.25);
		uv = w * 0.5 + 0.5;
		outside = uv.x < 0.0 || uv.x > 1.0 || uv.y < 0.0 || uv.y > 1.0;
		uv = clamp(uv, 0.0, 1.0);
	}
	vec2 px = 1.0 / extent;
	vec3 c = src(sp, uv);
	if (fx2.z > 0.0) {
		vec2 q = 1.0 / extent;
		float tl = luma(src(sp, uv + q * vec2(-1.0, -1.0))); float t = luma(src(sp, uv + q * vec2(0.0, -1.0))); float tr = luma(src(sp, uv + q * vec2(1.0, -1.0)));
		float l = luma(src(sp, uv + q * vec2(-1.0, 0.0))); float r = luma(src(sp, uv + q * vec2(1.0, 0.0)));
		float bl = luma(src(sp, uv + q * vec2(-1.0, 1.0))); float bo = luma(src(sp, uv + q * vec2(0.0, 1.0))); float br = luma(src(sp, uv + q * vec2(1.0, 1.0)));
		float gx = (tr + 2.0 * r + br) - (tl + 2.0 * l + bl);
		float gy = (bl + 2.0 * bo + br) - (tl + 2.0 * t + tr);
		c *= 1.0 - fx2.z * clamp(sqrt(gx * gx + gy * gy) * 3.0, 0.0, 1.0);
	}
	if (fx2.x > 0.0) {
		vec3 glow = vec3(0.0);
		vec2 o1 = px * 2.5;
		vec2 o2 = px * 5.0;
		glow += max(src(sp, uv + vec2(o1.x, 0.0)) - 0.6, 0.0) + max(src(sp, uv - vec2(o1.x, 0.0)) - 0.6, 0.0);
		glow += max(src(sp, uv + vec2(0.0, o1.y)) - 0.6, 0.0) + max(src(sp, uv - vec2(0.0, o1.y)) - 0.6, 0.0);
		glow += max(src(sp, uv + o1) - 0.6, 0.0) + max(src(sp, uv - o1) - 0.6, 0.0);
		glow += max(src(sp, uv + vec2(o1.x, -o1.y)) - 0.6, 0.0) + max(src(sp, uv - vec2(o1.x, -o1.y)) - 0.6, 0.0);
		glow += max(src(sp, uv + vec2(o2.x, 0.0)) - 0.6, 0.0) + max(src(sp, uv - vec2(o2.x, 0.0)) - 0.6, 0.0);
		glow += max(src(sp, uv + vec2(0.0, o2.y)) - 0.6, 0.0) + max(src(sp, uv - vec2(0.0, o2.y)) - 0.6, 0.0);
		c += glow * (fx2.x * 0.25);
	}
	vec2 d = uv - vec2(0.5);
	c *= 1.0 - fx.x * clamp(dot(d, d) * 2.0, 0.0, 1.0);
	c *= 1.0 - fx.y * 0.55 * mod(floor(FRAGCOORD.y), 2.0);
	c += (fract(sin(dot(floor(FRAGCOORD.xy), vec2(12.9898, 78.233))) * 43758.5453) - 0.5) * fx.z * 0.35;
	if (fx2.w > 0.0) {
		vec2 p = mod(floor(FRAGCOORD.xy), 4.0);
		float m = (4.0 * b2(mod(p.x, 2.0), mod(p.y, 2.0)) + b2(floor(p.x / 2.0), floor(p.y / 2.0))) / 16.0 - 0.46875;
		c += m * fx2.w / (fx.w > 1.5 ? fx.w - 1.0 : 31.0);
	}
	if (fx.w > 1.5) {
		c = floor(clamp(c, 0.0, 1.0) * (fx.w - 1.0) + 0.5) / (fx.w - 1.0);
	}
	COLOR = vec4(outside ? vec3(0.0) : c, 1.0);
}
"""


## A hidden overlay, to add as a child of the view (it fills it: anchors).
static func make() -> ColorRect:
	var r := ColorRect.new()
	r.mouse_filter = Control.MOUSE_FILTER_IGNORE
	r.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	var sh := Shader.new()
	sh.code = SHADER
	var m := ShaderMaterial.new()
	m.shader = sh
	r.material = m
	r.visible = false
	return r


## Sets the effects from a lighting() dictionary (the scene's first Environment); hides the overlay when none is on.
static func apply(rect: ColorRect, look: Dictionary) -> void:
	var v := clampf(float(look.get("vignette", 0.0)), 0.0, 1.0)
	var s := clampf(float(look.get("scanlines", 0.0)), 0.0, 1.0)
	var g := clampf(float(look.get("grain", 0.0)), 0.0, 1.0)
	var p := float(look.get("posterize", 0.0))
	p = clampf(p, 0.0, 64.0) if p >= 2.0 else 0.0
	var b := clampf(float(look.get("bloom", 0.0)), 0.0, 1.0)
	var cu := clampf(float(look.get("curve", 0.0)), 0.0, 1.0)
	var o := clampf(float(look.get("outline", 0.0)), 0.0, 1.0)
	var di := clampf(float(look.get("dither", 0.0)), 0.0, 1.0)
	rect.visible = v > 0.0 or s > 0.0 or g > 0.0 or p > 0.0 or b > 0.0 or cu > 0.0 or o > 0.0 or di > 0.0
	var m := rect.material as ShaderMaterial
	m.set_shader_parameter("fx", Vector4(v, s, g, p))
	m.set_shader_parameter("fx2", Vector4(b, cu, o, di))
	update_rect(rect)


## The shader needs the overlay's place in window pixels (the vignette is centered on it): call after it moved or resized.
static func update_rect(rect: ColorRect) -> void:
	if not rect.is_inside_tree():
		return
	var m := rect.material as ShaderMaterial
	var t := rect.get_viewport().get_final_transform()  # (a scaled window: FRAGCOORD is in real pixels)
	var r := rect.get_global_rect()
	var a := t * r.position
	var b := t * r.end
	m.set_shader_parameter("origin", a)
	m.set_shader_parameter("extent", Vector2(maxf(b.x - a.x, 1.0), maxf(b.y - a.y, 1.0)))
