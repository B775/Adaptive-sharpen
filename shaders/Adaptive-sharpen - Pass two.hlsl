// $MinimumShaderProfile: ps_3_0

// Copyright (c) 2015-2016, bacondither
// All rights reserved.
//
// Redistribution and use in source and binary forms, with or without
// modification, are permitted provided that the following conditions
// are met:
// 1. Redistributions of source code must retain the above copyright
//    notice, this list of conditions and the following disclaimer
//    in this position and unchanged.
// 2. Redistributions in binary form must reproduce the above copyright
//    notice, this list of conditions and the following disclaimer in the
//    documentation and/or other materials provided with the distribution.
//
// THIS SOFTWARE IS PROVIDED BY THE AUTHORS ``AS IS'' AND ANY EXPRESS OR
// IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED WARRANTIES
// OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE DISCLAIMED.
// IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR ANY DIRECT, INDIRECT,
// INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT
// NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE,
// DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY
// THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
// (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF
// THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.

// Second pass, MUST BE PLACED IMMEDIATELY AFTER THE FIRST PASS IN THE CHAIN

// Adaptive sharpen - version 2016-12-07 - (requires ps >= 3.0)
// Tuned for use post resize, EXPECTS FULL RANGE GAMMA LIGHT

sampler s0 : register(s0);
float2 p1  : register(c1);

//--------------------------------------- Settings ------------------------------------------------

#define curve_height    1.0                  // Main control of sharpening strength [>0]
                                             // 0.3 <-> 2.0 is a reasonable range of values

#define video_level_out false                // True to preserve BTB & WTW (minor summation error)
                                             // Normally it should be set to false

//-------------------------------------------------------------------------------------------------
// Defined values under this row are "optimal" DO NOT CHANGE IF YOU DO NOT KNOW WHAT YOU ARE DOING!

#define curveslope      0.4                  // Sharpening curve slope, high edge values

#define L_overshoot     0.003                // Max light overshoot before compression [>0.001]
#define L_compr_low     0.169                // Light compression, default (0.169=~9x)
#define L_compr_high    0.337                // Light compression, surrounded by edges (0.337=~4x)

#define D_overshoot     0.009                // Max dark overshoot before compression [>0.001]
#define D_compr_low     0.253                // Dark compression, default (0.253=~6x)
#define D_compr_high    0.504                // Dark compression, surrounded by edges (0.504=~2.5x)

#define max_scale_lim   0.1                  // Abs max change before compression (0.1=+-10%)

#define dW_lothr        0.3                  // Start interpolating between W1 and W2
#define dW_hithr        0.8                  // When dW is equal to W2

#define lowthr_mxw      0.11                 // Edge value for max lowthr weight [>0.01]

#define pm_p            0.75                 // Power mean p-value [>0-1.0]

#define alpha_out       1.0                  // MPDN requires the alpha channel output to be 1.0

//-------------------------------------------------------------------------------------------------
#define w_offset        2.0                  // Edge channel offset, must be the same in all passes
#define bounds_check    true                 // If edge data is outside bounds, make pixels green
//-------------------------------------------------------------------------------------------------

// Soft if, fast approx
#define soft_if(a,b,c) ( saturate((a + b + c - 3*w_offset + 0.05)/(abs(maxedge) + 0.02) - 0.85) )

// Soft limit, modified tanh
#define soft_lim(v,s)  ( ((exp(2*min(abs(v), s*16)/s) - 1)/(exp(2*min(abs(v), s*16)/s) + 1))*s )

// Weighted power mean
#define wpmean(a,b,w)  ( pow((w*pow(abs(a), pm_p) + abs(1-w)*pow(abs(b), pm_p)), (1.0/pm_p)) )

// Get destination pixel values
#define get(x,y)       ( tex2D(s0, tex + float2(x*(p1[0]), y*(p1[1]))) )
#define sat(inp)       ( float4(saturate((inp).xyz), (inp).w) )

// Maximum of four values
#define max4(a,b,c,d)  ( max(max(a,b), max(c,d)) )

// Colour to luma, fast approx gamma, avg of rec. 709 & 601 luma coeffs
#define CtL(RGB)       ( sqrt(dot(float3(0.2558, 0.6511, 0.0931), saturate((RGB)*abs(RGB)).rgb)) )

// Center pixel diff
#define mdiff(a,b,c,d,e,f,g) ( abs(luma[g]-luma[a]) + abs(luma[g]-luma[b])			 \
                             + abs(luma[g]-luma[c]) + abs(luma[g]-luma[d])			 \
                             + 0.5*(abs(luma[g]-luma[e]) + abs(luma[g]-luma[f])) )

float4 main(float2 tex : TEXCOORD0) : COLOR
{
	float4 orig  = tex2D(s0, tex);
	float c_edge = orig.w - w_offset;

	if (bounds_check == true)
	{
		if (c_edge > 24 || c_edge < -0.5) { return float4( 0, 1.0, 0, alpha_out ); }
	}

	// Get points, clip out of range colour data in c[0]
	// [                c22               ]
	// [           c24, c9,  c23          ]
	// [      c21, c1,  c2,  c3, c18      ]
	// [ c19, c10, c4,  c0,  c5, c11, c16 ]
	// [      c20, c6,  c7,  c8, c17      ]
	// [           c15, c12, c14          ]
	// [                c13               ]
	float4 c[25] = { sat( orig), get(-1,-1), get( 0,-1), get( 1,-1), get(-1, 0),
	                 get( 1, 0), get(-1, 1), get( 0, 1), get( 1, 1), get( 0,-2),
	                 get(-2, 0), get( 2, 0), get( 0, 2), get( 0, 3), get( 1, 2),
	                 get(-1, 2), get( 3, 0), get( 2, 1), get( 2,-1), get(-3, 0),
	                 get(-2, 1), get(-2,-1), get( 0,-3), get( 1,-2), get(-1,-2) };

	// Allow for higher overshoot if the current edge pixel is surrounded by similar edge pixels
	float maxedge = max4( max4(c[1].w,c[2].w,c[3].w,c[4].w), max4(c[5].w,c[6].w,c[7].w,c[8].w),
	                      max4(c[9].w,c[10].w,c[11].w,c[12].w), c[0].w ) - w_offset;

	// [          x          ]
	// [       z, x, w       ]
	// [    z, z, x, w, w    ]
	// [ y, y, y, 0, y, y, y ]
	// [    w, w, x, z, z    ]
	// [       w, x, z       ]
	// [          x          ]
	float sbe = soft_if(c[2].w,c[9].w,c[22].w) *soft_if(c[7].w,c[12].w,c[13].w)  // x dir
	          + soft_if(c[4].w,c[10].w,c[19].w)*soft_if(c[5].w,c[11].w,c[16].w)  // y dir
	          + soft_if(c[1].w,c[24].w,c[21].w)*soft_if(c[8].w,c[14].w,c[17].w)  // z dir
	          + soft_if(c[3].w,c[23].w,c[18].w)*soft_if(c[6].w,c[20].w,c[15].w); // w dir

	float2 cs = lerp( float2(L_compr_low,  D_compr_low),
	                  float2(L_compr_high, D_compr_high), smoothstep(2, 3.1, sbe) );

	// RGB to luma
	float c0_Y = CtL(c[0]);

	float luma[25] = { c0_Y, CtL(c[1]), CtL(c[2]), CtL(c[3]), CtL(c[4]), CtL(c[5]), CtL(c[6]),
	                   CtL(c[7]),  CtL(c[8]),  CtL(c[9]),  CtL(c[10]), CtL(c[11]), CtL(c[12]),
	                   CtL(c[13]), CtL(c[14]), CtL(c[15]), CtL(c[16]), CtL(c[17]), CtL(c[18]),
	                   CtL(c[19]), CtL(c[20]), CtL(c[21]), CtL(c[22]), CtL(c[23]), CtL(c[24]) };

	// Pre-calculated default squared kernel weights
	const float3 W1 = float3(0.5,           1.0, 1.41421356237); // 0.25, 1.0, 2.0
	const float3 W2 = float3(0.86602540378, 1.0, 0.5477225575);  // 0.75, 1.0, 0.3

	// Transition to a concave kernel if the center edge val is above thr
	float3 dW = pow(lerp( W1, W2, smoothstep(dW_lothr, dW_hithr, c_edge) ), 2);

	float mdiff_c0 = 0.02 + 3*( abs(luma[0]-luma[2]) + abs(luma[0]-luma[4])
	                          + abs(luma[0]-luma[5]) + abs(luma[0]-luma[7])
	                          + 0.25*(abs(luma[0]-luma[1]) + abs(luma[0]-luma[3])
	                                 +abs(luma[0]-luma[6]) + abs(luma[0]-luma[8])) );

	// Use lower weights for pixels in a more active area relative to center pixel area
	// This results in narrower and less visible overshoots around sharp edges
	float weights[12] = { ( min(mdiff_c0/mdiff(24, 21, 2,  4,  9,  10, 1),  dW.y) ),   // c1
	                      ( dW.x ),                                                    // c2
	                      ( min(mdiff_c0/mdiff(23, 18, 5,  2,  9,  11, 3),  dW.y) ),   // c3
	                      ( dW.x ),                                                    // c4
	                      ( dW.x ),                                                    // c5
	                      ( min(mdiff_c0/mdiff(4,  20, 15, 7,  10, 12, 6),  dW.y) ),   // c6
	                      ( dW.x ),                                                    // c7
	                      ( min(mdiff_c0/mdiff(5,  7,  17, 14, 12, 11, 8),  dW.y) ),   // c8
	                      ( min(mdiff_c0/mdiff(2,  24, 23, 22, 1,  3,  9),  dW.z) ),   // c9
	                      ( min(mdiff_c0/mdiff(20, 19, 21, 4,  1,  6,  10), dW.z) ),   // c10
	                      ( min(mdiff_c0/mdiff(17, 5,  18, 16, 3,  8,  11), dW.z) ),   // c11
	                      ( min(mdiff_c0/mdiff(13, 15, 7,  14, 6,  8,  12), dW.z) ) }; // c12

	weights[0] = (max(max((weights[8]  + weights[9])/4,  weights[0]), 0.25) + weights[0])/2;
	weights[2] = (max(max((weights[8]  + weights[10])/4, weights[2]), 0.25) + weights[2])/2;
	weights[5] = (max(max((weights[9]  + weights[11])/4, weights[5]), 0.25) + weights[5])/2;
	weights[7] = (max(max((weights[10] + weights[11])/4, weights[7]), 0.25) + weights[7])/2;

	// Calculate the negative part of the laplace kernel and the low threshold weight
	float lowthrsum   = 0;
	float weightsum   = 0;
	float neg_laplace = 0;

	[unroll]
	for (int pix = 0; pix < 12; ++pix)
	{
		float x      = saturate((c[pix + 1].w - w_offset - 0.01)/(lowthr_mxw - 0.01));
		float lowthr = x*x*(2.97 - 1.98*x) + 0.01; // x*x((3.0-c*3) - (2.0-c*2)*x) + c

		neg_laplace += pow(luma[pix + 1] + 0.06, 2.4)*(weights[pix]*lowthr);
		weightsum   += weights[pix]*lowthr;
		lowthrsum   += lowthr/12;
	}

	neg_laplace = pow(abs(neg_laplace/weightsum), (1.0/2.4)) - 0.06;

	// Compute sharpening magnitude function
	float sharpen_val = curve_height/(curve_height*curveslope*pow(abs(c_edge), 3.5) + 0.5);

	// Calculate sharpening diff and scale
	float sharpdiff = (c0_Y - neg_laplace)*(lowthrsum*sharpen_val*0.8 + 0.01);

	// Calculate local near min & max, partial sort
	[unroll]
	for (int i = 0; i < 3; ++i)
	{
		float temp;

		for (int i1 = i; i1 < 24-i; i1 += 2)
		{
			temp = luma[i1];
			luma[i1]   = min(luma[i1], luma[i1+1]);
			luma[i1+1] = max(temp, luma[i1+1]);
		}

		for (int i2 = 24-i; i2 > i; i2 -= 2)
		{
			temp = luma[i];
			luma[i]    = min(luma[i], luma[i2]);
			luma[i2]   = max(temp, luma[i2]);

			temp = luma[24-i];
			luma[24-i] = max(luma[24-i], luma[i2-1]);
			luma[i2-1] = min(temp, luma[i2-1]);
		}
	}

	float nmax = (max(luma[22] + luma[23]*2, c0_Y*3) + luma[24])/4;
	float nmin = (min(luma[2]  + luma[1]*2,  c0_Y*3) + luma[0])/4;

	// Calculate tanh scale factor, pos/neg
	float nmax_scale = min(nmax - c0_Y + min(L_overshoot, 1.0001 - nmax), max_scale_lim);
	float nmin_scale = min(c0_Y - nmin + min(D_overshoot, 0.0001 + nmin), max_scale_lim);

	// Soft limited anti-ringing with tanh, wpmean to control compression slope
	sharpdiff = wpmean( max(sharpdiff, 0), soft_lim( max(sharpdiff, 0), nmax_scale ), cs.x )
	          - wpmean( min(sharpdiff, 0), soft_lim( min(sharpdiff, 0), nmin_scale ), cs.y );

	// Compensate for saturation loss/gain while making pixels brighter/darker
	float satmul = max(1 + sharpdiff*1.5, 1.0/(1 + abs(sharpdiff)*0.45));
	float3 res = c0_Y + sharpdiff + (c[0].rgb - c0_Y)*satmul;

	return float4( (video_level_out == true ? orig.rgb + (res - c[0].rgb) : res), alpha_out );
}