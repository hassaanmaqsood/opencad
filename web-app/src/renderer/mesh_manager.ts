import * as THREE from 'three';
import {
  CadMeshRawBuffers,
  CadTessellatedSolidSlice,
  formatCadTopoId,
} from '../types/cad';

export class MeshManager {
  public group: THREE.Group;
  public solidMesh: THREE.Mesh;
  public edgeLines: THREE.LineSegments;

  public highlightFaceMesh: THREE.Mesh;
  public highlightEdgeLines: THREE.LineSegments;

  private currentBuffers: CadMeshRawBuffers | null = null;
  private currentSlice: CadTessellatedSolidSlice | null = null;
  private triangleToFaceId: Uint32Array | null = null;
  private edgeIds: Uint32Array | null = null;
  private triangleToTopoId: BigUint64Array | null = null;
  private edgeToTopoId: BigUint64Array | null = null;
  private solidType: string = 'box';

  constructor() {
    this.group = new THREE.Group();
    this.group.name = 'cad-model-root';

    // 1. Solid Mesh Material (Sleek CAD slate/blue-gray)
    const solidMaterial = new THREE.MeshStandardMaterial({
      color: 0x768fa5,
      roughness: 0.35,
      metalness: 0.1,
      polygonOffset: true,
      polygonOffsetFactor: 1, // push slightly behind edge lines to prevent z-fighting
      polygonOffsetUnits: 1,
      side: THREE.DoubleSide,
    });

    const solidGeometry = new THREE.BufferGeometry();
    this.solidMesh = new THREE.Mesh(solidGeometry, solidMaterial);
    this.solidMesh.name = 'cad-solid-mesh';
    this.solidMesh.castShadow = true;
    this.solidMesh.receiveShadow = true;
    this.group.add(this.solidMesh);

    // 2. Feature / Sharp Edge Lines Material (Crisp dark CAD outlines)
    const edgeMaterial = new THREE.LineBasicMaterial({
      color: 0x1e293b,
      linewidth: 2,
      depthTest: true,
    });

    const edgeGeometry = new THREE.BufferGeometry();
    this.edgeLines = new THREE.LineSegments(edgeGeometry, edgeMaterial);
    this.edgeLines.name = 'cad-edge-lines';
    this.group.add(this.edgeLines);

    // 3. Highlight Face Mesh Material (Translucent bright cyan/blue CAD selection overlay)
    const highlightFaceMaterial = new THREE.MeshBasicMaterial({
      color: 0x00b4d8,
      transparent: true,
      opacity: 0.65,
      depthTest: true,
      polygonOffset: true,
      polygonOffsetFactor: -2, // pull in front of base mesh
      polygonOffsetUnits: -2,
      side: THREE.DoubleSide,
    });

    const highlightFaceGeometry = new THREE.BufferGeometry();
    this.highlightFaceMesh = new THREE.Mesh(highlightFaceGeometry, highlightFaceMaterial);
    this.highlightFaceMesh.name = 'cad-face-highlight';
    this.highlightFaceMesh.visible = false;
    this.group.add(this.highlightFaceMesh);

    // 4. Highlight Edge Lines Material (Vibrant amber/gold CAD edge selection outline)
    const highlightEdgeMaterial = new THREE.LineBasicMaterial({
      color: 0xffb703,
      linewidth: 4,
      depthTest: false, // ensure selected edge is always visible
    });

    const highlightEdgeGeometry = new THREE.BufferGeometry();
    this.highlightEdgeLines = new THREE.LineSegments(highlightEdgeGeometry, highlightEdgeMaterial);
    this.highlightEdgeLines.name = 'cad-edge-highlight';
    this.highlightEdgeLines.visible = false;
    this.highlightEdgeLines.renderOrder = 999;
    this.group.add(this.highlightEdgeLines);
  }

  /**
   * Updates Three.js geometries from flat buffers transferred from the Web Worker.
   */
  public updateGeometry(buffers: CadMeshRawBuffers): void {
    this.currentBuffers = buffers;
    this.currentSlice = null;
    this.triangleToFaceId = buffers.triangleToFaceId;
    this.edgeIds = buffers.edgeIds;
    this.triangleToTopoId = null;
    this.edgeToTopoId = null;
    this.solidType = buffers.metadata.solidType;

    // Reset highlights
    this.setHighlightedFace(null);
    this.setHighlightedEdge(null);

    // Construct Solid BufferGeometry
    const solidGeometry = new THREE.BufferGeometry();
    solidGeometry.setAttribute(
      'position',
      new THREE.BufferAttribute(buffers.positions, 3)
    );
    solidGeometry.setAttribute(
      'normal',
      new THREE.BufferAttribute(buffers.normals, 3)
    );
    solidGeometry.setIndex(new THREE.BufferAttribute(buffers.indices, 1));

    // Construct custom faceId BufferAttribute on vertices
    const vertexCount = buffers.positions.length / 3;
    const vertexFaceIds = new Float32Array(vertexCount);
    const triCount = buffers.indices.length / 3;

    for (let t = 0; t < triCount; t++) {
      const faceId = buffers.triangleToFaceId[t];
      const i0 = buffers.indices[t * 3];
      const i1 = buffers.indices[t * 3 + 1];
      const i2 = buffers.indices[t * 3 + 2];
      vertexFaceIds[i0] = faceId;
      vertexFaceIds[i1] = faceId;
      vertexFaceIds[i2] = faceId;
    }
    solidGeometry.setAttribute('faceId', new THREE.BufferAttribute(vertexFaceIds, 1));

    solidGeometry.computeBoundingBox();
    solidGeometry.computeBoundingSphere();

    this.solidMesh.geometry.dispose();
    this.solidMesh.geometry = solidGeometry;

    // Construct Edge Lines BufferGeometry
    const edgeGeometry = new THREE.BufferGeometry();
    edgeGeometry.setAttribute(
      'position',
      new THREE.BufferAttribute(buffers.edgeVertices, 3)
    );
    this.edgeLines.geometry.dispose();
    this.edgeLines.geometry = edgeGeometry;
  }

  /**
   * Updates Three.js geometries from a CadTessellatedSolidSlice (Wave 3 persistent CadTopoId).
   */
  public updateFromSlice(slice: CadTessellatedSolidSlice): void {
    this.currentSlice = slice;
    this.currentBuffers = null;
    this.triangleToTopoId = slice.triangleToFaceId;
    this.edgeToTopoId = slice.edgeToTopoId;
    this.solidType = slice.metadata.solidType || 'parametric-dag';

    // Populate backward-compatible Uint32 arrays
    const triCount = slice.triangleToFaceId.length;
    this.triangleToFaceId = new Uint32Array(triCount);
    for (let i = 0; i < triCount; i++) {
      this.triangleToFaceId[i] = Number(slice.triangleToFaceId[i] & 0xffffn);
    }

    const edgeCount = slice.edgeToTopoId.length;
    this.edgeIds = new Uint32Array(edgeCount);
    for (let i = 0; i < edgeCount; i++) {
      this.edgeIds[i] = Number(slice.edgeToTopoId[i] & 0xffffn);
    }

    // Reset highlights
    this.setHighlightedFace(null);
    this.setHighlightedEdge(null);

    // Construct Solid BufferGeometry
    const solidGeometry = new THREE.BufferGeometry();
    solidGeometry.setAttribute(
      'position',
      new THREE.BufferAttribute(slice.positions, 3)
    );
    solidGeometry.setAttribute(
      'normal',
      new THREE.BufferAttribute(slice.normals, 3)
    );
    solidGeometry.setIndex(new THREE.BufferAttribute(slice.indices, 1));

    solidGeometry.computeBoundingBox();
    solidGeometry.computeBoundingSphere();

    this.solidMesh.geometry.dispose();
    this.solidMesh.geometry = solidGeometry;

    // Construct Edge Lines BufferGeometry
    const edgeGeometry = new THREE.BufferGeometry();
    edgeGeometry.setAttribute(
      'position',
      new THREE.BufferAttribute(slice.edgePolylines, 3)
    );
    this.edgeLines.geometry.dispose();
    this.edgeLines.geometry = edgeGeometry;
  }

  /**
   * Look up face ID in O(1) from raycaster triangle index.
   */
  public getFaceIdFromTriangleIndex(triangleIndex: number): number | null {
    if (this.triangleToFaceId && triangleIndex >= 0 && triangleIndex < this.triangleToFaceId.length) {
      return this.triangleToFaceId[triangleIndex];
    }
    return null;
  }

  /**
   * Look up persistent 64-bit CadTopoId from raycaster triangle index.
   */
  public getFaceTopoIdFromTriangleIndex(triangleIndex: number): bigint | null {
    if (this.triangleToTopoId && triangleIndex >= 0 && triangleIndex < this.triangleToTopoId.length) {
      return this.triangleToTopoId[triangleIndex];
    }
    if (this.triangleToFaceId && triangleIndex >= 0 && triangleIndex < this.triangleToFaceId.length) {
      return BigInt(this.triangleToFaceId[triangleIndex]);
    }
    return null;
  }

  /**
   * Look up edge ID from edge line segment index.
   */
  public getEdgeIdFromSegmentIndex(segmentIndex: number): number | null {
    if (this.edgeIds && segmentIndex >= 0 && segmentIndex < this.edgeIds.length) {
      return this.edgeIds[segmentIndex];
    }
    return null;
  }

  /**
   * Look up persistent 64-bit CadTopoId from edge line segment index.
   */
  public getEdgeTopoIdFromSegmentIndex(segmentIndex: number): bigint | null {
    if (this.edgeToTopoId && segmentIndex >= 0 && segmentIndex < this.edgeToTopoId.length) {
      return this.edgeToTopoId[segmentIndex];
    }
    if (this.edgeIds && segmentIndex >= 0 && segmentIndex < this.edgeIds.length) {
      return BigInt(this.edgeIds[segmentIndex]);
    }
    return null;
  }

  /**
   * Highlights a discrete topological face by extracting its triangles.
   * Supports both legacy faceId (number) and 64-bit persistent CadTopoId (bigint).
   */
  public setHighlightedFace(faceId: bigint | number | null): void {
    if (faceId === null) {
      this.highlightFaceMesh.visible = false;
      return;
    }

    if (this.currentSlice && this.triangleToTopoId) {
      const { positions, normals, indices } = this.currentSlice;
      const triCount = indices.length / 3;
      const matchedIndices: number[] = [];
      const targetBig = typeof faceId === 'bigint' ? faceId : BigInt(faceId);

      for (let t = 0; t < triCount; t++) {
        const tid = this.triangleToTopoId[t];
        if (tid === targetBig || (typeof faceId === 'number' && Number(tid & 0xffffn) === faceId)) {
          matchedIndices.push(indices[t * 3], indices[t * 3 + 1], indices[t * 3 + 2]);
        }
      }

      if (matchedIndices.length === 0) {
        this.highlightFaceMesh.visible = false;
        return;
      }

      const highlightGeometry = new THREE.BufferGeometry();
      highlightGeometry.setAttribute('position', new THREE.BufferAttribute(positions, 3));
      highlightGeometry.setAttribute('normal', new THREE.BufferAttribute(normals, 3));
      highlightGeometry.setIndex(new THREE.BufferAttribute(new Uint32Array(matchedIndices), 1));

      this.highlightFaceMesh.geometry.dispose();
      this.highlightFaceMesh.geometry = highlightGeometry;
      this.highlightFaceMesh.visible = true;
      return;
    }

    if (!this.currentBuffers || !this.triangleToFaceId) {
      this.highlightFaceMesh.visible = false;
      return;
    }

    const targetNum = typeof faceId === 'bigint' ? Number(faceId & 0xffffn) : faceId;
    const { positions, normals, indices } = this.currentBuffers;
    const triCount = indices.length / 3;
    const matchedIndices: number[] = [];

    for (let t = 0; t < triCount; t++) {
      if (this.triangleToFaceId[t] === targetNum) {
        matchedIndices.push(indices[t * 3], indices[t * 3 + 1], indices[t * 3 + 2]);
      }
    }

    if (matchedIndices.length === 0) {
      this.highlightFaceMesh.visible = false;
      return;
    }

    const highlightGeometry = new THREE.BufferGeometry();
    highlightGeometry.setAttribute('position', new THREE.BufferAttribute(positions, 3));
    highlightGeometry.setAttribute('normal', new THREE.BufferAttribute(normals, 3));
    highlightGeometry.setIndex(new THREE.BufferAttribute(new Uint32Array(matchedIndices), 1));

    this.highlightFaceMesh.geometry.dispose();
    this.highlightFaceMesh.geometry = highlightGeometry;
    this.highlightFaceMesh.visible = true;
  }

  /**
   * Highlights a sharp feature edge by extracting its line vertices.
   * Supports both legacy edgeId (number) and 64-bit persistent CadTopoId (bigint).
   */
  public setHighlightedEdge(edgeId: bigint | number | null): void {
    if (edgeId === null) {
      this.highlightEdgeLines.visible = false;
      return;
    }

    if (this.currentSlice && this.edgeToTopoId) {
      const { edgePolylines } = this.currentSlice;
      const totalSegments = this.edgeToTopoId.length;
      const matchedVertices: number[] = [];
      const targetBig = typeof edgeId === 'bigint' ? edgeId : BigInt(edgeId);

      for (let s = 0; s < totalSegments; s++) {
        const eid = this.edgeToTopoId[s];
        if (eid === targetBig || (typeof edgeId === 'number' && Number(eid & 0xffffn) === edgeId)) {
          const offset = s * 6;
          for (let i = 0; i < 6; i++) {
            matchedVertices.push(edgePolylines[offset + i]);
          }
        }
      }

      if (matchedVertices.length === 0) {
        this.highlightEdgeLines.visible = false;
        return;
      }

      const highlightGeometry = new THREE.BufferGeometry();
      highlightGeometry.setAttribute(
        'position',
        new THREE.BufferAttribute(new Float32Array(matchedVertices), 3)
      );

      this.highlightEdgeLines.geometry.dispose();
      this.highlightEdgeLines.geometry = highlightGeometry;
      this.highlightEdgeLines.visible = true;
      return;
    }

    if (!this.currentBuffers || !this.edgeIds) {
      this.highlightEdgeLines.visible = false;
      return;
    }

    const targetNum = typeof edgeId === 'bigint' ? Number(edgeId & 0xffffn) : edgeId;
    const { edgeVertices } = this.currentBuffers;
    const totalSegments = this.edgeIds.length;
    const matchedVertices: number[] = [];

    for (let s = 0; s < totalSegments; s++) {
      if (this.edgeIds[s] === targetNum) {
        const offset = s * 6;
        for (let i = 0; i < 6; i++) {
          matchedVertices.push(edgeVertices[offset + i]);
        }
      }
    }

    if (matchedVertices.length === 0) {
      this.highlightEdgeLines.visible = false;
      return;
    }

    const highlightGeometry = new THREE.BufferGeometry();
    highlightGeometry.setAttribute(
      'position',
      new THREE.BufferAttribute(new Float32Array(matchedVertices), 3)
    );

    this.highlightEdgeLines.geometry.dispose();
    this.highlightEdgeLines.geometry = highlightGeometry;
    this.highlightEdgeLines.visible = true;
  }

  /**
   * Human-readable label for CAD sub-shapes.
   */
  public getFaceLabel(faceId: number): string {
    if (this.solidType === 'box') {
      const labels: Record<number, string> = {
        1: 'Face #1 (+X Right)',
        2: 'Face #2 (-X Left)',
        3: 'Face #3 (+Y Top)',
        4: 'Face #4 (-Y Bottom)',
        5: 'Face #5 (+Z Front)',
        6: 'Face #6 (-Z Back)',
      };
      return labels[faceId] || `Face #${faceId}`;
    } else if (this.solidType === 'cylinder') {
      const labels: Record<number, string> = {
        1: 'Face #1 (Top Cap)',
        2: 'Face #2 (Bottom Cap)',
        3: 'Face #3 (Lateral Side)',
      };
      return labels[faceId] || `Face #${faceId}`;
    }
    return `Face #${faceId}`;
  }

  public getFaceTopoLabel(topoId: bigint | number): string {
    if (this.currentSlice) {
      return formatCadTopoId(topoId);
    }
    return this.getFaceLabel(typeof topoId === 'bigint' ? Number(topoId & 0xffffn) : topoId);
  }

  public getEdgeLabel(edgeId: number): string {
    if (this.solidType === 'cylinder') {
      const labels: Record<number, string> = {
        1: 'Edge #1 (Top Rim Circle)',
        2: 'Edge #2 (Bottom Rim Circle)',
      };
      return labels[edgeId] || `Edge #${edgeId}`;
    }
    return `Edge #${edgeId}`;
  }

  public getEdgeTopoLabel(topoId: bigint | number): string {
    if (this.currentSlice) {
      return formatCadTopoId(topoId);
    }
    return this.getEdgeLabel(typeof topoId === 'bigint' ? Number(topoId & 0xffffn) : topoId);
  }
}

