import * as THREE from 'three';
import {
  CadMeshRawBuffers,
  CadTessellatedSolidSlice,
  formatCadTopoId,
} from '../types/cad';
import type { VisualDiffData } from '../core-shell/PluginTypes';

export class MeshManager {
  public group: THREE.Group;
  public solidMesh: THREE.Mesh;
  public edgeLines: THREE.LineSegments;

  public highlightFaceMesh: THREE.Mesh;
  public highlightEdgeLines: THREE.LineSegments;
  public instancedMesh: THREE.InstancedMesh | null = null;
  public lodGroup: THREE.LOD | null = null;
  public diffGroup: THREE.Group | null = null;

  private currentBuffers: CadMeshRawBuffers | null = null;
  private currentSlice: CadTessellatedSolidSlice | null = null;
  private triangleToFaceId: Uint32Array | null = null;
  private edgeIds: Uint32Array | null = null;
  private triangleToTopoId: BigUint64Array | null = null;
  private edgeToTopoId: BigUint64Array | null = null;
  private solidType: string = 'box';
  private defaultSolidMaterial: THREE.Material;

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
    this.defaultSolidMaterial = solidMaterial;

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
    if (this.instancedMesh) {
      this.group.remove(this.instancedMesh);
      this.instancedMesh.dispose();
      this.instancedMesh = null;
    }
    if (this.lodGroup) {
      this.group.remove(this.lodGroup);
      this.lodGroup = null;
    }
    this.solidMesh.visible = true;
    this.edgeLines.visible = true;

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
    if (this.instancedMesh) {
      this.group.remove(this.instancedMesh);
      this.instancedMesh.dispose();
      this.instancedMesh = null;
    }
    if (this.lodGroup) {
      this.group.remove(this.lodGroup);
      this.lodGroup = null;
    }
    this.solidMesh.visible = true;
    this.edgeLines.visible = true;

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

  /**
   * Wave 5: Updates instanced assembly meshes using Three.js InstancedMesh for high-performance rendering.
   */
  public updateAssemblyInstances(
    transforms: Float32Array,
    instanceCount: number,
    baseGeometry?: THREE.BufferGeometry
  ): void {
    if (this.instancedMesh) {
      this.group.remove(this.instancedMesh);
      this.instancedMesh.dispose();
      this.instancedMesh = null;
    }
    if (this.lodGroup) {
      this.group.remove(this.lodGroup);
      this.lodGroup = null;
    }

    if (instanceCount <= 0) return;

    let geom = baseGeometry || this.solidMesh.geometry;
    if (!geom.getAttribute('position') || geom.getAttribute('position').count === 0) {
      geom = new THREE.BoxGeometry(0.8, 0.8, 0.8);
    }

    const material = (this.solidMesh.material as THREE.Material).clone();
    this.instancedMesh = new THREE.InstancedMesh(geom, material, instanceCount);
    this.instancedMesh.name = 'cad-assembly-instanced-mesh';
    this.instancedMesh.castShadow = true;
    this.instancedMesh.receiveShadow = true;

    const mat = new THREE.Matrix4();
    for (let i = 0; i < instanceCount; i++) {
      mat.fromArray(transforms, i * 16);
      this.instancedMesh.setMatrixAt(i, mat);
    }
    this.instancedMesh.instanceMatrix.needsUpdate = true;
    this.group.add(this.instancedMesh);

    // Hide single solid mesh during instanced assembly display
    this.solidMesh.visible = false;
    this.edgeLines.visible = false;
  }

  /**
   * Wave 5: Updates multi-deflection LOD using THREE.LOD.
   */
  public updateLOD(
    coarseGeom: THREE.BufferGeometry,
    mediumGeom: THREE.BufferGeometry,
    fineGeom: THREE.BufferGeometry
  ): void {
    if (this.lodGroup) {
      this.group.remove(this.lodGroup);
      this.lodGroup = null;
    }
    if (this.instancedMesh) {
      this.group.remove(this.instancedMesh);
      this.instancedMesh.dispose();
      this.instancedMesh = null;
    }

    const material = this.solidMesh.material;
    const lod = new THREE.LOD();
    lod.name = 'cad-lod-group';

    const fineMesh = new THREE.Mesh(fineGeom, material);
    fineMesh.name = 'cad-lod-fine';
    const mediumMesh = new THREE.Mesh(mediumGeom, material);
    mediumMesh.name = 'cad-lod-medium';
    const coarseMesh = new THREE.Mesh(coarseGeom, material);
    coarseMesh.name = 'cad-lod-coarse';

    lod.addLevel(fineMesh, 0);
    lod.addLevel(mediumMesh, 12);
    lod.addLevel(coarseMesh, 30);

    this.lodGroup = lod;
    this.group.add(lod);
    this.solidMesh.visible = false;
  }

  /**
   * Wave 6B: Sets 3D Boolean Visual Diff overlay (Green = added, Red = removed).
   */
  public setVisualDiff(diff: VisualDiffData | null): void {
    if (this.diffGroup) {
      this.group.remove(this.diffGroup);
      this.diffGroup.traverse((obj) => {
        if ((obj as THREE.Mesh).geometry) {
          (obj as THREE.Mesh).geometry.dispose();
        }
      });
      this.diffGroup = null;
    }

    if (!diff) {
      if (this.solidMesh.material instanceof THREE.MeshStandardMaterial) {
        this.solidMesh.material.transparent = false;
        this.solidMesh.material.opacity = 1.0;
        this.solidMesh.material.needsUpdate = true;
      }
      return;
    }

    // Semi-transparent base mesh so additions and removals stand out
    if (this.solidMesh.material instanceof THREE.MeshStandardMaterial) {
      this.solidMesh.material.transparent = true;
      this.solidMesh.material.opacity = 0.35;
      this.solidMesh.material.needsUpdate = true;
    }

    this.diffGroup = new THREE.Group();
    this.diffGroup.name = 'cad-diff-overlay';

    // 1. Added Volume Mesh (Emerald Green #22c55e)
    if (diff.addedPositions && diff.addedIndices && diff.addedPositions.length > 0) {
      const addedGeom = new THREE.BufferGeometry();
      addedGeom.setAttribute('position', new THREE.BufferAttribute(diff.addedPositions, 3));
      addedGeom.setIndex(new THREE.BufferAttribute(diff.addedIndices, 1));
      addedGeom.computeVertexNormals();

      const addedMat = new THREE.MeshStandardMaterial({
        color: 0x22c55e,
        transparent: true,
        opacity: 0.75,
        roughness: 0.3,
        side: THREE.DoubleSide,
      });

      const addedMesh = new THREE.Mesh(addedGeom, addedMat);
      addedMesh.name = 'diff-added-mesh';
      this.diffGroup.add(addedMesh);
    }

    // 2. Removed Volume Mesh (Crimson Red #ef4444)
    if (diff.removedPositions && diff.removedIndices && diff.removedPositions.length > 0) {
      const removedGeom = new THREE.BufferGeometry();
      removedGeom.setAttribute('position', new THREE.BufferAttribute(diff.removedPositions, 3));
      removedGeom.setIndex(new THREE.BufferAttribute(diff.removedIndices, 1));
      removedGeom.computeVertexNormals();

      const removedMat = new THREE.MeshStandardMaterial({
        color: 0xef4444,
        transparent: true,
        opacity: 0.75,
        roughness: 0.3,
        side: THREE.DoubleSide,
      });

      const removedMesh = new THREE.Mesh(removedGeom, removedMat);
      removedMesh.name = 'diff-removed-mesh';
      this.diffGroup.add(removedMesh);
    }

    this.group.add(this.diffGroup);
  }

  public setInspectionMode(mode: 'standard' | 'zebra' | 'curvature' | 'draft'): void {
    if (mode === 'zebra') {
      this.solidMesh.material = new THREE.ShaderMaterial({
        vertexShader: `
          varying vec3 vNormal;
          varying vec3 vViewPosition;
          void main() {
            vNormal = normalize(normalMatrix * normal);
            vec4 mvPosition = modelViewMatrix * vec4(position, 1.0);
            vViewPosition = -mvPosition.xyz;
            gl_Position = projectionMatrix * mvPosition;
          }
        `,
        fragmentShader: `
          varying vec3 vNormal;
          varying vec3 vViewPosition;
          void main() {
            vec3 normal = normalize(vNormal);
            vec3 viewDir = normalize(vViewPosition);
            vec3 refl = reflect(-viewDir, normal);
            float stripe = sin(refl.y * 50.0) * 0.5 + 0.5;
            stripe = step(0.5, stripe);
            vec3 color = mix(vec3(0.08, 0.08, 0.1), vec3(0.95, 0.95, 0.95), stripe);
            gl_FragColor = vec4(color, 1.0);
          }
        `,
        side: THREE.DoubleSide,
      });
    } else if (mode === 'draft') {
      this.solidMesh.material = new THREE.ShaderMaterial({
        vertexShader: `
          varying vec3 vWorldNormal;
          void main() {
            vWorldNormal = normalize((modelMatrix * vec4(normal, 0.0)).xyz);
            gl_Position = projectionMatrix * modelViewMatrix * vec4(position, 1.0);
          }
        `,
        fragmentShader: `
          varying vec3 vWorldNormal;
          void main() {
            float cosAngle = dot(normalize(vWorldNormal), vec3(0.0, 0.0, 1.0));
            float angleDeg = degrees(acos(clamp(cosAngle, -1.0, 1.0))) - 90.0;
            vec3 color = angleDeg >= 3.0 ? vec3(0.1, 0.8, 0.2) : (angleDeg >= 0.0 ? vec3(0.9, 0.8, 0.1) : vec3(0.9, 0.1, 0.1));
            gl_FragColor = vec4(color, 1.0);
          }
        `,
        side: THREE.DoubleSide,
      });
    } else {
      this.solidMesh.material = this.defaultSolidMaterial;
    }
  }
}

