#include "ReShade.fxh"
#ifndef BUFFER_COLOR_SPACE
	#define BUFFER_COLOR_SPACE 1
#endif
uniform int Cut < ui_type = "combo"; ui_items = "Green backdrop\0Depth\0"; ui_label = "Cut him out by (Depth needs a working depth buffer and is the only one that handles swimming)"; > = 0;
uniform float GreenTol < ui_type = "slider"; ui_min = 0.0; ui_max = 0.5; ui_step = 0.005; ui_label = "Green backdrop: how much greener than red and blue a pixel must be to be cut away (lower if green shows, raise if parts of him vanish)"; > = 0.1;
uniform float KeyMax < ui_type = "slider"; ui_min = 0.0005; ui_max = 0.5; ui_step = 0.0005; ui_label = "Key depth (linear, 1 = far plane)"; > = 0.061;
uniform float WaterTol < ui_type = "slider"; ui_min = 0.0; ui_max = 0.2; ui_step = 0.005; ui_label = "Swimming: how much nearer than the water a pixel must be to be Michael (raise if specks of water show, lower if he is eaten at the waterline)"; > = 0.08;
uniform float HdrWhite < ui_type = "slider"; ui_min = 80.0; ui_max = 500.0; ui_step = 1.0; ui_label = "HDR only: the brightness (nits) that becomes white in the picture sent to BeamNG"; > = 203.0;
uniform int Hdr < ui_type = "combo"; ui_items = "Auto\0Never\0Always\0"; ui_label = "Treat GTA's picture as HDR (Auto follows what ReShade reports; change it if he looks far too dark or washed out in BeamNG)"; > = 0;

float3 Sdr(float3 c)
{
	if (Hdr == 1 || (Hdr == 0 && BUFFER_COLOR_SPACE != 3)) return c;
	float3 p = pow(saturate(c), 1.0 / 78.84375);
	float3 l = 10000.0 * pow(max(p - 0.8359375, 0.0) / (18.8515625 - 18.6875 * p), 1.0 / 0.1593017578125) / HdrWhite;
	l = float3(dot(l, float3(1.6605, -0.5876, -0.0728)), dot(l, float3(-0.1246, 1.1329, -0.0083)), dot(l, float3(-0.0182, -0.1006, 1.1187)));
	return pow(saturate(l), 1.0 / 2.2);
}
float Near(float2 uv)
{
	float d = tex2Dlod(ReShade::DepthBuffer, float4(uv, 0, 0)).x;
#if RESHADE_DEPTH_INPUT_IS_REVERSED
	return d;
#else
	return 1.0 - d;
#endif
}
float Lin(float n)
{
	float d = 1.0 - n;
	return d / (RESHADE_DEPTH_LINEARIZATION_FAR_PLANE - d * (RESHADE_DEPTH_LINEARIZATION_FAR_PLANE - 1.0));
}
float4 PS_Key(float4 pos : SV_Position, float2 uv : TEXCOORD) : SV_Target
{
	float3 c = Sdr(tex2D(ReShade::BackBuffer, uv).rgb);
	bool key = true, sea = false;
	if (Cut == 0)
	{
		float m = max(c.r, c.b);
		key = c.g - m < GreenTol;
		c.g = min(c.g, m);
	}
	else
	{
		float n = Near(uv);
		key = Lin(n) < KeyMax;
		float w = 1.0, s[6];
		for (int i = 0; i < 6; i++) { s[i] = Near(float2(0.02 + 0.192 * i, uv.y)); w = min(w, s[i]); }
		int same = 0;
		for (int j = 0; j < 6; j++) if (s[j] <= w * (1.0 + 0.5 * WaterTol)) same++;
		sea = key && same >= 3 && n <= w * (1.0 + WaterTol);
		key = key && !sea;
	}
	c.b = (floor((c.b * 255.0 + 0.5) * 0.5) * 2.0 + (sea ? 1.0 : 0.0)) / 255.0;
	return float4(c, key ? 1.0 : 0.0);
}
technique GtaKey { pass { VertexShader = PostProcessVS; PixelShader = PS_Key; } }
