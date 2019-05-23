#line 0 "osd/mtlPatchBSpline.metal"

//
//   Copyright 2015 Pixar
//
//   Licensed under the Apache License, Version 2.0 (the "Apache License")
//   with the following modification; you may not use this file except in
//   compliance with the Apache License and the following modification to it:
//   Section 6. Trademarks. is deleted and replaced with:
//
//   6. Trademarks. This License does not grant permission to use the trade
//      names, trademarks, service marks, or product names of the Licensor
//      and its affiliates, except as required to comply with Section 4(c) of
//      the License and to reproduce the content of the NOTICE file.
//
//   You may obtain a copy of the Apache License at
//
//       http://www.apache.org/licenses/LICENSE-2.0
//
//   Unless required by applicable law or agreed to in writing, software
//   distributed under the Apache License with the above modification is
//   distributed on an "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
//   KIND, either express or implied. See the Apache License for the specific
//   language governing permissions and limitations under the Apache License.
//

//----------------------------------------------------------
// Patches.BSpline.Hull
//----------------------------------------------------------

void OsdComputePerVertex(
        float4 vertexPosition,
        threadgroup HullVertex& hullVertex,
        int vertexId,
        float4x4 ModelViewProjectionMatrix,
        OsdPatchParamBufferSet osdBuffers
        )
{
    hullVertex.position = vertexPosition;
#if OSD_ENABLE_PATCH_CULL
    float4 clipPos = mul(ModelViewProjectionMatrix, vertexPosition);
    short3 clip0 = short3(clipPos.x < clipPos.w,
                          clipPos.y < clipPos.w,
                          clipPos.z < clipPos.w);
    short3 clip1 = short3(clipPos.x > -clipPos.w,
                          clipPos.y > -clipPos.w,
                          clipPos.z > -clipPos.w);
    hullVertex.clipFlag = short3(clip0) + 2*short3(clip1);
#endif
}

//----------------------------------------------------------
// Patches.BSpline.Factors
//----------------------------------------------------------

void OsdComputePerPatchBSplineFactors(
        int3 patchParam,
        float tessLevel,
        float4x4 projectionMatrix,
        float4x4 modelViewMatrix,
        device OsdPerPatchVertexBezier* patch
#if !USE_PTVS_FACTORS
        ,device OsdPerPatchTessFactors& patchFactors
#endif
        ,device MTLQuadTessellationFactorsHalf& quadFactors
        )
{
    float4 tessLevelOuter = float4(0,0,0,0);
    float2 tessLevelInner = float2(0,0);
    float4 tessOuterLo = float4(0,0,0,0);
    float4 tessOuterHi = float4(0,0,0,0);

#if OSD_ENABLE_SCREENSPACE_TESSELLATION
    OsdGetTessLevelsAdaptiveLimitPoints(
        tessLevel,
        projectionMatrix,
        modelViewMatrix,
        patch,
        patchParam,
        tessLevelOuter,
        tessLevelInner,
        tessOuterLo,
        tessOuterHi
        );
#else
    OsdGetTessLevelsUniform(
        tessLevel,
        patchParam,
        tessLevelOuter,
        tessLevelInner,
        tessOuterLo,
        tessOuterHi
        );
#endif

    quadFactors.edgeTessellationFactor[0] = tessLevelOuter[0];
    quadFactors.edgeTessellationFactor[1] = tessLevelOuter[1];
    quadFactors.edgeTessellationFactor[2] = tessLevelOuter[2];
    quadFactors.edgeTessellationFactor[3] = tessLevelOuter[3];
    quadFactors.insideTessellationFactor[0] = tessLevelInner[0];
    quadFactors.insideTessellationFactor[1] = tessLevelInner[1];
#if !USE_PTVS_FACTORS
    patchFactors.tessOuterLo = tessOuterLo;
    patchFactors.tessOuterHi = tessOuterHi;
#endif
}

void OsdComputePerPatchFactors(
        int3 patchParam,
        float tessLevel,
        unsigned patchID,
        float4x4 projectionMatrix,
        float4x4 modelViewMatrix,
        OsdPatchParamBufferSet osdBuffer,
        threadgroup PatchVertexType* patchVertices,
        device MTLQuadTessellationFactorsHalf& quadFactors
        )
{
    OsdComputePerPatchBSplineFactors(
        patchParam,
        tessLevel,
        projectionMatrix,
        modelViewMatrix,
        osdBuffer.perPatchVertexBuffer + patchID * CONTROL_POINTS_PER_PATCH,
#if !USE_PTVS_FACTORS
        osdBuffer.patchTessBuffer[patchID],
#endif
        quadFactors
        );
}

//----------------------------------------------------------
// Patches.BSpline.Vertex
//----------------------------------------------------------

void OsdComputePerPatchVertex(
        int3 patchParam,
        unsigned ID,
        unsigned PrimitiveID,
        unsigned ControlID,
        threadgroup PatchVertexType* patchVertices,
        OsdPatchParamBufferSet osdBuffers
        )
{
    OsdComputePerPatchVertexBSpline(patchParam, ID,
        patchVertices, osdBuffers.perPatchVertexBuffer[ControlID]);
}

//----------------------------------------------------------
// Patches.BSpline.Domain
//----------------------------------------------------------

template<typename PerPatchVertexBezier>
OsdPatchVertex ds_regular_patches(
        const float TessLevel,
#if !USE_PTVS_FACTORS
        float4 tessOuterHi,
        float4 tessOuterLo,
#endif
        PerPatchVertexBezier cv,
        int3 patchParam,
        float2 domainCoord
        )
{
    OsdPatchVertex output;

    float3 P, dPu, dPv;
    float3 N, dNu, dNv;
    float2 vSegments;

#if !USE_PTVS_FACTORS
    float2 UV = OsdGetTessParameterization(domainCoord,
                                           tessOuterLo,
                                           tessOuterHi);
#else
    auto transitionMask = OsdGetPatchTransitionMask(patchParam);
    float4 tessLevelMin = float4(1)
    + float4(((transitionMask & 8) >> 3),
             ((transitionMask & 1) >> 0),
             ((transitionMask & 2) >> 1),
             ((transitionMask & 4) >> 2));

    float2 UV = OsdGetTessParameterization(domainCoord,
                                           tessLevelMin,
                                           float4(0));
#endif

    OsdEvalPatchBezier(patchParam, UV, cv, P, dPu, dPv, N, dNu, dNv, vSegments);
    output.normal = N;
    output.tangent = dPu;
    output.bitangent = dPv;
#if OSD_COMPUTE_NORMAL_DERIVATIVES
    output.Nu = dNu;
    output.Nv = dNv;
#endif
#if OSD_PATCH_ENABLE_SINGLE_CREASE
    output.vSegments = vSegments;
#endif

    output.patchCoord = OsdInterpolatePatchCoord(UV, patchParam);
    output.position = P;
    return output;
}

#if USE_STAGE_IN
template<typename PerPatchVertexBezier>
#endif
OsdPatchVertex OsdComputePatch(
        float tessLevel,
        float2 domainCoord,
        unsigned patchID,
#if USE_STAGE_IN
        PerPatchVertexBezier osdPatch
#else
        OsdVertexBufferSet osdBuffers
#endif
        )
{
    return ds_regular_patches(
            tessLevel,
#if !USE_PTVS_FACTORS
#if USE_STAGE_IN
            osdPatch.tessOuterHi,
            osdPatch.tessOuterLo,
#else
            osdBuffers.patchTessBuffer[patchID].tessOuterHi,
            osdBuffers.patchTessBuffer[patchID].tessOuterLo,
#endif
#endif
#if USE_STAGE_IN
            osdPatch.cv,
            osdPatch.patchParam,
#else
            osdBuffers.perPatchVertexBuffer + patchID * VERTEX_CONTROL_POINTS_PER_PATCH,
            osdBuffers.patchParamBuffer[patchID],
#endif
            domainCoord
            );
}

