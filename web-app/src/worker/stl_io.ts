import { CadTessellatedSolidSlice } from '../types/cad';

export interface StlExportOptions {
  binary?: boolean;
  deflection?: number;
  solidName?: string;
}

export function computeFacetNormal(
  v1: [number, number, number],
  v2: [number, number, number],
  v3: [number, number, number]
): [number, number, number] {
  const ax = v2[0] - v1[0];
  const ay = v2[1] - v1[1];
  const az = v2[2] - v1[2];

  const bx = v3[0] - v1[0];
  const by = v3[1] - v1[1];
  const bz = v3[2] - v1[2];

  let nx = ay * bz - az * by;
  let ny = az * bx - ax * bz;
  let nz = ax * by - ay * bx;

  const lenSq = nx * nx + ny * ny + nz * nz;
  if (lenSq > 1e-12) {
    const invLen = 1.0 / Math.sqrt(lenSq);
    nx *= invLen;
    ny *= invLen;
    nz *= invLen;
  } else {
    nx = 0.0;
    ny = 0.0;
    nz = 1.0;
  }
  return [nx, ny, nz];
}

export function exportStlBinary(slice: CadTessellatedSolidSlice, solidName: string = 'OpenCAD Model'): Uint8Array {
  const triCount = Math.floor(slice.indices.length / 3);
  const totalBytes = 84 + triCount * 50;
  const buffer = new Uint8Array(totalBytes);
  const view = new DataView(buffer.buffer);

  // 80-byte header
  const enc = new TextEncoder();
  const headerBytes = enc.encode(solidName.slice(0, 80));
  buffer.set(headerBytes, 0);

  // 4-byte triangle count
  view.setUint32(80, triCount, true);

  const pos = slice.positions;
  const idx = slice.indices;

  let offset = 84;
  for (let t = 0; t < triCount; t++) {
    const i0 = idx[t * 3];
    const i1 = idx[t * 3 + 1];
    const i2 = idx[t * 3 + 2];

    const v1: [number, number, number] = [pos[i0 * 3], pos[i0 * 3 + 1], pos[i0 * 3 + 2]];
    const v2: [number, number, number] = [pos[i1 * 3], pos[i1 * 3 + 1], pos[i1 * 3 + 2]];
    const v3: [number, number, number] = [pos[i2 * 3], pos[i2 * 3 + 1], pos[i2 * 3 + 2]];

    const [nx, ny, nz] = computeFacetNormal(v1, v2, v3);

    // Normal
    view.setFloat32(offset, nx, true); offset += 4;
    view.setFloat32(offset, ny, true); offset += 4;
    view.setFloat32(offset, nz, true); offset += 4;

    // V1
    view.setFloat32(offset, v1[0], true); offset += 4;
    view.setFloat32(offset, v1[1], true); offset += 4;
    view.setFloat32(offset, v1[2], true); offset += 4;

    // V2
    view.setFloat32(offset, v2[0], true); offset += 4;
    view.setFloat32(offset, v2[1], true); offset += 4;
    view.setFloat32(offset, v2[2], true); offset += 4;

    // V3
    view.setFloat32(offset, v3[0], true); offset += 4;
    view.setFloat32(offset, v3[1], true); offset += 4;
    view.setFloat32(offset, v3[2], true); offset += 4;

    // Attribute byte count
    view.setUint16(offset, 0, true); offset += 2;
  }

  return buffer;
}

export function exportStlAscii(slice: CadTessellatedSolidSlice, solidName: string = 'opencad_model'): string {
  const triCount = Math.floor(slice.indices.length / 3);
  const pos = slice.positions;
  const idx = slice.indices;

  let out = `solid ${solidName}\n`;
  for (let t = 0; t < triCount; t++) {
    const i0 = idx[t * 3];
    const i1 = idx[t * 3 + 1];
    const i2 = idx[t * 3 + 2];

    const v1: [number, number, number] = [pos[i0 * 3], pos[i0 * 3 + 1], pos[i0 * 3 + 2]];
    const v2: [number, number, number] = [pos[i1 * 3], pos[i1 * 3 + 1], pos[i1 * 3 + 2]];
    const v3: [number, number, number] = [pos[i2 * 3], pos[i2 * 3 + 1], pos[i2 * 3 + 2]];

    const [nx, ny, nz] = computeFacetNormal(v1, v2, v3);

    out += `  facet normal ${nx.toFixed(6)} ${ny.toFixed(6)} ${nz.toFixed(6)}\n`;
    out += `    outer loop\n`;
    out += `      vertex ${v1[0].toFixed(6)} ${v1[1].toFixed(6)} ${v1[2].toFixed(6)}\n`;
    out += `      vertex ${v2[0].toFixed(6)} ${v2[1].toFixed(6)} ${v2[2].toFixed(6)}\n`;
    out += `      vertex ${v3[0].toFixed(6)} ${v3[1].toFixed(6)} ${v3[2].toFixed(6)}\n`;
    out += `    endloop\n`;
    out += `  endfacet\n`;
  }
  out += `endsolid ${solidName}\n`;
  return out;
}

export function exportStl(slice: CadTessellatedSolidSlice, options?: StlExportOptions): Uint8Array | string {
  const binary = options?.binary !== false;
  const name = options?.solidName || 'opencad_model';
  if (binary) {
    return exportStlBinary(slice, name);
  } else {
    return exportStlAscii(slice, name);
  }
}
