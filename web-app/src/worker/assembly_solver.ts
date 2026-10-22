import {
  CadAssemblyInstance,
  CadAssemblyMate,
  CadAssemblyMateType,
  CadAssemblySolveStatus,
  CadSolveState,
} from '../types/cad';

export function solveAssemblyClient(
  instances: CadAssemblyInstance[],
  mates: CadAssemblyMate[],
  maxIterations = 50,
  convergenceTol = 1e-6
): { transforms: Float32Array; status: CadAssemblySolveStatus } {
  const instanceCount = instances.length;
  const transforms = new Float32Array(instanceCount * 16);

  // Initialize transforms from instances
  const positions: [number, number, number][] = [];
  const rotations: [number, number, number][] = []; // Euler angles in radians

  for (let i = 0; i < instanceCount; i++) {
    const init = instances[i].initialTransform;
    transforms.set(init, i * 16);
    positions.push([init[12], init[13], init[14]]);
    rotations.push([0, 0, 0]);
  }

  if (instanceCount === 0 || mates.length === 0) {
    return {
      transforms,
      status: {
        solveState: CadSolveState.SOLVED,
        totalDof: 0,
        iterations: 0,
        maxResidual: 0,
        conflictingCount: 0,
      },
    };
  }

  // Map instance id to index
  const idMap = new Map<number, number>();
  for (let i = 0; i < instanceCount; i++) {
    idMap.set(instances[i].instanceId, i);
  }

  let iter = 0;
  let maxResidual = 0;

  while (iter < maxIterations) {
    iter++;
    maxResidual = 0;

    for (const mate of mates) {
      const idx1 = idMap.get(mate.instance1Id);
      const idx2 = idMap.get(mate.instance2Id);
      if (idx1 === undefined || idx2 === undefined) continue;

      const p1 = positions[idx1];
      const p2 = positions[idx2];
      const isFree2 = !instances[idx2].isGrounded;

      switch (mate.type) {
        case CadAssemblyMateType.COINCIDENT: {
          // Align position
          const dx = p1[0] - p2[0];
          const dy = p1[1] - p2[1];
          const dz = p1[2] - p2[2];
          const dist = Math.sqrt(dx * dx + dy * dy + dz * dz);
          if (dist > maxResidual) maxResidual = dist;

          if (isFree2) {
            p2[0] = p1[0];
            p2[1] = p1[1];
            p2[2] = p1[2];
          }
          break;
        }

        case CadAssemblyMateType.CONCENTRIC: {
          // Align X and Y (collinear Z axis)
          const dx = p1[0] - p2[0];
          const dy = p1[1] - p2[1];
          const radDist = Math.sqrt(dx * dx + dy * dy);
          if (radDist > maxResidual) maxResidual = radDist;

          if (isFree2) {
            p2[0] = p1[0];
            p2[1] = p1[1];
          }
          break;
        }

        case CadAssemblyMateType.PARALLEL: {
          // Align rotations
          const diffRot = Math.abs(rotations[idx1][0] - rotations[idx2][0]);
          if (diffRot > maxResidual) maxResidual = diffRot;
          if (isFree2) {
            rotations[idx2][0] = rotations[idx1][0];
            rotations[idx2][1] = rotations[idx1][1];
          }
          break;
        }

        case CadAssemblyMateType.DISTANCE: {
          // Target Euclidean / normal distance
          const targetDist = mate.parameterValue;
          const currDist = p2[2] - p1[2];
          const diff = Math.abs(currDist - targetDist);
          if (diff > maxResidual) maxResidual = diff;

          if (isFree2) {
            p2[2] = p1[2] + targetDist;
          }
          break;
        }

        case CadAssemblyMateType.ANGLE: {
          const targetAngle = mate.parameterValue;
          const currAngle = Math.abs(rotations[idx2][2] - rotations[idx1][2]);
          const diff = Math.abs(currAngle - targetAngle);
          if (diff > maxResidual) maxResidual = diff;
          if (isFree2) {
            rotations[idx2][2] = rotations[idx1][2] + targetAngle;
          }
          break;
        }

        case CadAssemblyMateType.GEAR: {
          const ratio = mate.parameterValue || 1.0;
          const targetRot = rotations[idx1][2] * ratio;
          const diff = Math.abs(rotations[idx2][2] - targetRot);
          if (diff > maxResidual) maxResidual = diff;
          if (isFree2) {
            rotations[idx2][2] = targetRot;
          }
          break;
        }
      }
    }

    if (maxResidual <= convergenceTol) {
      break;
    }
  }

  // Update transforms matrix buffer
  for (let i = 0; i < instanceCount; i++) {
    const offset = i * 16;
    const px = positions[i][0];
    const py = positions[i][1];
    const pz = positions[i][2];

    const rx = rotations[i][0];
    const ry = rotations[i][1];
    const rz = rotations[i][2];

    // Compute column-major 4x4 from Euler angles + translation
    const cx = Math.cos(rx), sx = Math.sin(rx);
    const cy = Math.cos(ry), sy = Math.sin(ry);
    const cz = Math.cos(rz), sz = Math.sin(rz);

    // Col 0
    transforms[offset + 0] = cy * cz;
    transforms[offset + 1] = cy * sz;
    transforms[offset + 2] = -sy;
    transforms[offset + 3] = 0;

    // Col 1
    transforms[offset + 4] = sx * sy * cz - cx * sz;
    transforms[offset + 5] = sx * sy * sz + cx * cz;
    transforms[offset + 6] = sx * cy;
    transforms[offset + 7] = 0;

    // Col 2
    transforms[offset + 8] = cx * sy * cz + sx * sz;
    transforms[offset + 9] = cx * sy * sz - sx * cz;
    transforms[offset + 10] = cx * cy;
    transforms[offset + 11] = 0;

    // Col 3 (Translation)
    transforms[offset + 12] = px;
    transforms[offset + 13] = py;
    transforms[offset + 14] = pz;
    transforms[offset + 15] = 1.0;
  }

  return {
    transforms,
    status: {
      solveState: maxResidual <= convergenceTol ? CadSolveState.SOLVED : CadSolveState.UNDER_CONSTRAINED,
      totalDof: 0,
      iterations: iter,
      maxResidual,
      conflictingCount: 0,
    },
  };
}
