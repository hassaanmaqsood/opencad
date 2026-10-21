import * as THREE from 'three';
import { SubShapeSelection } from '../types/cad';
import { MeshManager } from './mesh_manager';

export class CadPicker {
  private raycaster: THREE.Raycaster;
  private camera: THREE.Camera;
  private domElement: HTMLElement;
  private meshManager: MeshManager;

  constructor(camera: THREE.Camera, domElement: HTMLElement, meshManager: MeshManager) {
    this.camera = camera;
    this.domElement = domElement;
    this.meshManager = meshManager;

    this.raycaster = new THREE.Raycaster();
    // Allow forgiving selection threshold for thin CAD edge lines
    this.raycaster.params.Line = { threshold: 0.15 };
  }

  /**
   * Raycasts at the normalized viewport coordinate (nx in [-1, 1], ny in [-1, 1]).
   */
  public pickNormalized(nx: number, ny: number, preferEdge: boolean = false): SubShapeSelection {
    this.raycaster.setFromCamera(new THREE.Vector2(nx, ny), this.camera);

    // 1. If edge picking is preferred or when testing edge lines
    if (preferEdge) {
      const edgeIntersects = this.raycaster.intersectObject(this.meshManager.edgeLines);
      if (edgeIntersects.length > 0) {
        const hit = edgeIntersects[0];
        // In LineSegments, segment index is index / 2
        const segmentIndex = hit.index !== undefined ? Math.floor(hit.index / 2) : 0;
        const edgeId = this.meshManager.getEdgeIdFromSegmentIndex(segmentIndex);
        if (edgeId !== null) {
          return {
            type: 'edge',
            edgeId,
            point: [hit.point.x, hit.point.y, hit.point.z],
            label: this.meshManager.getEdgeLabel(edgeId),
          };
        }
      }
    }

    // 2. Pick Solid Mesh Faces
    const solidIntersects = this.raycaster.intersectObject(this.meshManager.solidMesh);
    if (solidIntersects.length > 0) {
      const hit = solidIntersects[0];
      const faceIndex = hit.faceIndex;
      if (faceIndex !== undefined && faceIndex !== null) {
        const faceId = this.meshManager.getFaceIdFromTriangleIndex(faceIndex);
        if (faceId !== null) {
          return {
            type: 'face',
            faceId,
            point: [hit.point.x, hit.point.y, hit.point.z],
            normal: hit.face
              ? [hit.face.normal.x, hit.face.normal.y, hit.face.normal.z]
              : undefined,
            label: this.meshManager.getFaceLabel(faceId),
          };
        }
      }
    }

    // 3. Fallback to check edge if not checked previously
    if (!preferEdge) {
      const edgeIntersects = this.raycaster.intersectObject(this.meshManager.edgeLines);
      if (edgeIntersects.length > 0) {
        const hit = edgeIntersects[0];
        const segmentIndex = hit.index !== undefined ? Math.floor(hit.index / 2) : 0;
        const edgeId = this.meshManager.getEdgeIdFromSegmentIndex(segmentIndex);
        if (edgeId !== null) {
          return {
            type: 'edge',
            edgeId,
            point: [hit.point.x, hit.point.y, hit.point.z],
            label: this.meshManager.getEdgeLabel(edgeId),
          };
        }
      }
    }

    return { type: 'none' };
  }

  /**
   * Raycasts at CSS client coordinates.
   */
  public pickClient(clientX: number, clientY: number, preferEdge: boolean = false): SubShapeSelection {
    const rect = this.domElement.getBoundingClientRect();
    const nx = ((clientX - rect.left) / rect.width) * 2 - 1;
    const ny = -((clientY - rect.top) / rect.height) * 2 + 1;
    return this.pickNormalized(nx, ny, preferEdge);
  }
}
