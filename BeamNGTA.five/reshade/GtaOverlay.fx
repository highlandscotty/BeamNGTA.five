#include "ReShade.fxh"

texture GtaTex < source = "GtaPlaceholder.png"; > { Width = 1920; Height = 1080; Format = RGBA8; };
sampler GtaSamp { Texture = GtaTex; AddressU = BORDER; AddressV = BORDER; MinFilter = LINEAR; MagFilter = LINEAR; };
sampler GtaPt { Texture = GtaTex; AddressU = BORDER; AddressV = BORDER; MinFilter = POINT; MagFilter = POINT; MipFilter = POINT; };

uniform float Scale < ui_type = "slider"; ui_min = 0.1; ui_max = 1.0; ui_label = "Overlay scale (1 = full-screen composite)"; > = 1.0;
uniform bool UseOcclusion < ui_label = "Hide Michael behind BeamNG objects (needs BeamNG depth)"; > = true;
uniform float OccMargin < ui_type = "slider"; ui_min = 0.2; ui_max = 3.0; ui_label = "Occlusion margin (m)"; > = 0.6;
uniform float BeamNear < ui_type = "slider"; ui_min = 0.01; ui_max = 1.0; ui_label = "BeamNG near clip (m)"; > = 0.1;
uniform float3 ShadowColor < ui_type = "color"; ui_label = "Michael's shadow: what is left of the ground's colour (match BeamNG's own shadows; white = no shadow)"; > = float3(0.47, 0.52, 0.62);
uniform float ShadowSoft < ui_type = "slider"; ui_min = 0.2; ui_max = 4.0; ui_label = "Michael's shadow: edge softness"; > = 1.0;
uniform float ColorMul < ui_type = "slider"; ui_min = 0.5; ui_max = 1.5; ui_label = "Michael brightness"; > = 1.0;
uniform float GlassReflect < ui_type = "slider"; ui_min = 0.0; ui_max = 1.0; ui_label = "Seated in a car: how much of the window glass shows over Michael"; > = 0.35;
uniform bool DepthReversed < ui_label = "BeamNG depth is reversed (near = 1). Leave on; turn off only if he is hidden everywhere"; > = true;
uniform float WaterHide < ui_type = "slider"; ui_min = 0.0; ui_max = 1.0; ui_label = "In water: how much of him below the surface is hidden"; > = 0.75;
uniform float UnderShow < ui_type = "slider"; ui_min = 0.0; ui_max = 1.0; ui_label = "Swimming: how strongly his body shows under the surface"; > = 0.9;
uniform float UnderKey < ui_type = "slider"; ui_min = 0.01; ui_max = 0.2; ui_label = "Swimming: how different from open sea a pixel must be to count as his body (lower shows more of him and more stray water)"; > = 0.05;
uniform float BloomOver < ui_type = "slider"; ui_min = 0.0; ui_max = 3.0; ui_label = "Bloom over the whole picture, BeamNG and Michael together (0 = off)"; > = 0.35;
uniform float BloomThresh < ui_type = "slider"; ui_min = 0.3; ui_max = 1.0; ui_label = "Bloom: brightness where it starts"; > = 0.7;
uniform int Debug < ui_type = "combo"; ui_items = "Off\0BeamNG depth\0GTA frame\0"; > = 0;
uniform float GtaAspect = 1.7778;
uniform float2 FeetUV = float2(0.5, 0.8);
uniform float BodyH = 0.0;
uniform float CardS = 1.0;
uniform float2 CardO = float2(0.0, 0.0);
uniform float ZNew = 3.2;
uniform float2 TanH = float2(0.577, 0.577);
uniform float2 FeetT = float2(0.0, -1.0);
uniform float SunsetTint < ui_type = "slider"; ui_min = 0.0; ui_max = 1.5; ui_label = "Orange tint over BeamNG at sunrise and sunset"; > = 1.0;
uniform float3 SunC = float3(0.0, 0.0, 0.0);
uniform float3 UpC = float3(0.0, 1.0, 0.0);
uniform float3 FeetC = float3(0.0, -1.5, 3.2);
uniform float4 CapA[20];
uniform float4 CapB[20];
uniform float3 CapC = float3(0.0, 0.0, 3.2);
uniform float CapN = 0.0;
uniform float InCar = 0.0;
uniform float WaterH = 0.0;
uniform float4 Shade = float4(0.0, 0.0, 0.0, 0.0);
uniform float Ghost = 1.0;
uniform float Show = 1.0;

float RawD(float2 uv) { return tex2Dlod(ReShade::DepthBuffer, float4(uv, 0, 0)).x; }

float4 PS_Overlay(float4 pos : SV_Position, float2 uv : TEXCOORD) : SV_Target
{
	float4 back = tex2D(ReShade::BackBuffer, uv);
	if (Show < 0.5) return back;
	{ float su = dot(SunC, UpC); float k = SunsetTint * smoothstep(0.6, 0.12, su) * smoothstep(-0.3, 0.0, su); back.rgb = lerp(back.rgb, back.rgb * float3(1.5, 0.78, 0.4), saturate(k)); }
	float ab = float(BUFFER_WIDTH) / float(BUFFER_HEIGHT);

	float2 o = uv;
	if (Scale < 0.999) {
		o = (uv - (1.0 - Scale)) / Scale;
		if (o.x < 0.0 || o.y < 0.0 || o.x > 1.0 || o.y > 1.0) return back;
		back.rgb *= 0.6;
	}

	float2 sn = float2((o.x * 2.0 - 1.0) * ab * TanH.x, (1.0 - o.y * 2.0) * TanH.x);
	float2 so = sn * CardS + CardO;
	float2 g = float2(0.5 + so.x / (2.0 * TanH.y * GtaAspect), 0.5 - so.y / (2.0 * TanH.y));
	float t = ZNew;

	bool depthOk = true;
	bool rev = DepthReversed;
	float dn = RawD(uv);
	dn = rev ? dn : 1.0 - dn;
	float z = BeamNear / max(dn, 0.0000001);

	if (Debug == 1) {
		return float4(saturate(z / 20.0).xxx, 1.0);
	}
	if (Debug == 2) return float4(tex2Dlod(GtaSamp, float4(g, 0, 0)).rgb, 1.0);

	float2 px = float2(1.0 / 1920.0, 1.0 / 1080.0);
	float3 acc = float3(0.0, 0.0, 0.0);
	float cnt = 0.0;
	[unroll] for (int j = -1; j <= 1; j++) {
		[unroll] for (int i = -1; i <= 1; i++) {
			float4 s = tex2Dlod(GtaSamp, float4(g + float2(i, j) * px, 0, 0));
			float c = s.a > 0.002 ? 1.0 : 0.0;
			acc += s.rgb * c;
			cnt += c;
		}
	}
	float a = saturate((cnt - 3.0) / 5.0);
	float3 col = acc / max(cnt, 1.0) * ColorMul;

	float vis = 1.0;
	if (UseOcclusion && depthOk) vis = InCar > 0.5 ? saturate((z - (t - 0.12)) / 0.15) : saturate((z - (t - OccMargin)) / 0.25);

	float3 rgb = back.rgb;
	float sunUp = dot(SunC, UpC);
	if (InCar > 0.5) {
	}
	else if (CapN > 0.5 && depthOk && sunUp > 0.03 && Scale > 0.999) {
		float2 fuv = float2(0.5 + FeetT.x / (2.0 * TanH.x * ab), 0.5 - FeetT.y / (2.0 * TanH.x));
		float zcal = 1.0;
		if (fuv.x > 0.02 && fuv.x < 0.98 && fuv.y > 0.02 && fuv.y < 0.98) {
			float df = RawD(fuv); df = rev ? df : 1.0 - df;
			float zr = FeetC.z / (BeamNear / max(df, 0.0000001));
			if (zr > 0.9 && zr < 1.1) zcal = zr;
		}
		float zc = z * zcal;
		float3 P = float3(sn.x * zc, sn.y * zc, zc);
		float3 rc = P - CapC;
		if (zc < 300.0 && length(rc + SunC * max(-dot(SunC, rc), 0.0)) < 1.5) {
			float sh = 0.0, hq = 0.0;
			for (int k = 0; k < 20; k++) {
				float3 A = CapA[k].xyz, d = CapB[k].xyz - A, r = P - A;
				float dd = dot(d, d), b = dot(d, SunC), c = dot(d, r), f = dot(SunC, r);
				float den = dd - b * b;
				float t = den > 0.00001 ? saturate((c - b * f) / den) : 0.0;
				float s = max(b * t - f, 0.0);
				t = saturate((c + b * s) / max(dd, 0.00001));
				float dist = length(r + SunC * s - d * t);
				float pen = (0.012 + 0.03 * s) * ShadowSoft;
				float cs = 1.0 - smoothstep(CapA[k].w - pen, CapA[k].w + pen, dist);
				if (cs > sh) { sh = cs; hq = dot(A + d * t - FeetC, UpC); }
			}
			sh *= 1.0 - lerp(Shade.z, Shade.w, saturate(hq / 1.7));
			rgb *= lerp(float3(1.0, 1.0, 1.0), ShadowColor, sh);
		}
	}
	else if (BodyH > 0.01 && FeetT.y > -0.99) {
		float2 f = float2(0.5 + FeetT.x / (2.0 * TanH.x * ab), 0.5 - FeetT.y / (2.0 * TanH.x));
		float k = (TanH.y / TanH.x) / max(CardS, 0.05);
		f.y -= BodyH * 0.02 * k;
		float R = BodyH * 0.32 * k;
		float dx = (o.x - f.x) * ab / R;
		float dy = (o.y - f.y) / (R * 0.35);
		rgb *= lerp(float3(1.0, 1.0, 1.0), ShadowColor, exp(-(dx * dx + dy * dy) * 1.5) * vis * (1.0 - Shade.z));
	}

	if (InCar > 1.5) col = col * 0.85 + back.rgb * GlassReflect;
	if (WaterH > 0.05) a *= 1.0 - WaterHide * smoothstep(0.05, -0.12, dot(float3(sn * t, t) - FeetC, UpC) - WaterH);
	if (WaterH < -0.05 && CapN > 0.5) {
		float4 sp = tex2Dlod(GtaPt, float4(g, 0, 0));
		float b8 = floor(sp.b * 255.0 + 0.5);
		float3 D = normalize(float3(sn, 1.0));
		if (sp.a < 0.5 && b8 - 2.0 * floor(b8 * 0.5) > 0.5 && length(CapC - D * dot(CapC, D)) < 1.8) {
			float m = 0.0;
			for (int k = 0; k < 20; k++) {
				float3 A = CapA[k].xyz, d = CapB[k].xyz - A, r = -A;
				float dd = dot(d, d), b = dot(d, D), c = dot(d, r), f = dot(D, r);
				float den = dd - b * b;
				float u = den > 0.00001 ? saturate((c - b * f) / den) : 0.0;
				float s = max(b * u - f, 0.0);
				u = saturate((c + b * s) / max(dd, 0.00001));
				m = max(m, 1.0 - smoothstep(CapA[k].w + 0.05, CapA[k].w + 0.22, length(D * s - A - d * u)));
			}
			float3 sea = lerp(tex2Dlod(GtaSamp, float4(0.02, g.y, 0, 0)).rgb, tex2Dlod(GtaSamp, float4(0.98, g.y, 0, 0)).rgb, g.x);
			float body = smoothstep(UnderKey, UnderKey * 3.0, length(sp.rgb - sea));
			rgb = lerp(rgb, sp.rgb * ColorMul, body * m * UnderShow * vis);
		}
	}
	col *= lerp(float3(1.0, 1.0, 1.0), ShadowColor, lerp(Shade.x, Shade.y, saturate(dot(float3(sn * t, t) - FeetC, UpC) / 1.7)));
	rgb = lerp(rgb, col, a * vis);
	float3 outc = lerp(back.rgb, rgb, Ghost);
	return float4(outc, 1.0);
}
texture BloomTexA { Width = BUFFER_WIDTH / 4; Height = BUFFER_HEIGHT / 4; Format = RGBA16F; };
texture BloomTexB { Width = BUFFER_WIDTH / 4; Height = BUFFER_HEIGHT / 4; Format = RGBA16F; };
sampler BloomSA { Texture = BloomTexA; AddressU = CLAMP; AddressV = CLAMP; MinFilter = LINEAR; MagFilter = LINEAR; };
sampler BloomSB { Texture = BloomTexB; AddressU = CLAMP; AddressV = CLAMP; MinFilter = LINEAR; MagFilter = LINEAR; };

float4 PS_BrightDown(float4 pos : SV_Position, float2 uv : TEXCOORD) : SV_Target
{
	if (Show < 0.5) return float4(0.0, 0.0, 0.0, 1.0);
	float2 px = float2(BUFFER_RCP_WIDTH, BUFFER_RCP_HEIGHT) * 2.0;
	float3 c = tex2D(ReShade::BackBuffer, uv + float2(-px.x, -px.y)).rgb;
	c += tex2D(ReShade::BackBuffer, uv + float2(px.x, -px.y)).rgb;
	c += tex2D(ReShade::BackBuffer, uv + float2(-px.x, px.y)).rgb;
	c += tex2D(ReShade::BackBuffer, uv + float2(px.x, px.y)).rgb;
	return float4(max(c * 0.25 - BloomThresh, 0.0), 1.0);
}

float4 PS_BlurH(float4 pos : SV_Position, float2 uv : TEXCOORD) : SV_Target
{
	float2 st = float2(BUFFER_RCP_WIDTH * 10.0, 0.0);
	float3 c = float3(0.0, 0.0, 0.0);
	float ws = 0.0;
	[unroll] for (int k = -4; k <= 4; k++) {
		float w = exp(-float(k * k) / 8.0);
		c += tex2D(BloomSA, uv + st * float(k) * 0.25).rgb * w;
		ws += w;
	}
	return float4(c / ws, 1.0);
}

float4 PS_BlurV(float4 pos : SV_Position, float2 uv : TEXCOORD) : SV_Target
{
	float2 st = float2(0.0, BUFFER_RCP_HEIGHT * 10.0);
	float3 c = float3(0.0, 0.0, 0.0);
	float ws = 0.0;
	[unroll] for (int k = -4; k <= 4; k++) {
		float w = exp(-float(k * k) / 8.0);
		c += tex2D(BloomSB, uv + st * float(k) * 0.25).rgb * w;
		ws += w;
	}
	return float4(c / ws, 1.0);
}

float4 PS_BloomComp(float4 pos : SV_Position, float2 uv : TEXCOORD) : SV_Target
{
	float3 back = tex2D(ReShade::BackBuffer, uv).rgb;
	if (Show < 0.5 || BloomOver < 0.001) return float4(back, 1.0);
	return float4(back + tex2D(BloomSA, uv).rgb * BloomOver * 3.0, 1.0);
}

technique GtaOverlay
{
	pass { VertexShader = PostProcessVS; PixelShader = PS_Overlay; }
	pass { VertexShader = PostProcessVS; PixelShader = PS_BrightDown; RenderTarget = BloomTexA; }
	pass { VertexShader = PostProcessVS; PixelShader = PS_BlurH; RenderTarget = BloomTexB; }
	pass { VertexShader = PostProcessVS; PixelShader = PS_BlurV; RenderTarget = BloomTexA; }
	pass { VertexShader = PostProcessVS; PixelShader = PS_BloomComp; }
}
