import Foundation
import simd

/// One piece of a scene mesh (an ARKit `ARMeshAnchor`), copied out of ARKit's buffers.
///
/// ARKit may keep updating the Metal buffers behind an anchor, so a chunk owns plain copies: it is
/// safe to hand to a background task. Vertices are tightly packed `float x y z` (12 bytes each) in the
/// anchor's local space; faces are `bytesPerIndex`-wide (2 or 4) triples of vertex indices.
public struct MeshChunk: Sendable, Equatable {
    public var transform: simd_float4x4
    public var vertexData: Data
    public var vertexCount: Int
    public var faceData: Data
    public var faceCount: Int
    public var bytesPerIndex: Int

    public init(
        transform: simd_float4x4, vertexData: Data, vertexCount: Int,
        faceData: Data, faceCount: Int, bytesPerIndex: Int
    ) {
        self.transform = transform
        self.vertexData = vertexData
        self.vertexCount = vertexCount
        self.faceData = faceData
        self.faceCount = faceCount
        self.bytesPerIndex = bytesPerIndex
    }

    /// False when the buffers are shorter than the counts claim, or the index width is unsupported.
    public var isConsistent: Bool {
        (bytesPerIndex == 2 || bytesPerIndex == 4)
            && vertexData.count >= vertexCount * 12
            && faceData.count >= faceCount * 3 * bytesPerIndex
    }
}
