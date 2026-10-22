import * as THREE from 'three';

export interface CrossSectionUniforms {
  uCellSize: { value: number };
  uWallThickness: { value: number };
  uTpmsType: { value: number }; // 0: Gyroid, 1: SchwarzP, 2: Diamond, 3: Lidinoid, 4: Neovius
  uPlaneElevation: { value: number };
  uShowContours: { value: boolean };
  uContourSpacing: { value: number };
  uStressFactor: { value: number };
}

const vertexShader = `
  varying vec3 vWorldPosition;
  varying vec2 vUv;

  void main() {
    vUv = uv;
    vec4 worldPos = modelMatrix * vec4(position, 1.0);
    vWorldPosition = worldPos.xyz;
    gl_Position = projectionMatrix * viewMatrix * worldPos;
  }
`;

const fragmentShader = `
  varying vec3 vWorldPosition;
  varying vec2 vUv;

  uniform float uCellSize;
  uniform float uWallThickness;
  uniform int uTpmsType;
  uniform float uPlaneElevation;
  uniform bool uShowContours;
  uniform float uContourSpacing;
  uniform float uStressFactor;

  const float PI = 3.14159265358979323846;

  float evalTpms(vec3 p) {
    float k = (2.0 * PI) / max(uCellSize, 0.1);
    vec3 kp = p * k;

    float sx = sin(kp.x);
    float cx = cos(kp.x);
    float sy = sin(kp.y);
    float cy = cos(kp.y);
    float sz = sin(kp.z);
    float cz = cos(kp.z);

    if (uTpmsType == 0) {
      // Gyroid
      return sx * cy + sy * cz + sz * cx;
    } else if (uTpmsType == 1) {
      // Schwarz P
      return cx + cy + cz;
    } else if (uTpmsType == 2) {
      // Schwarz D (Diamond)
      return cx * cy * cz - sx * sy * sz;
    } else if (uTpmsType == 3) {
      // Lidinoid
      float s2x = sin(2.0 * kp.x);
      float s2y = sin(2.0 * kp.y);
      float s2z = sin(2.0 * kp.z);
      float c2x = cos(2.0 * kp.x);
      float c2y = cos(2.0 * kp.y);
      float c2z = cos(2.0 * kp.z);
      float t1 = 0.5 * (s2x * cy * sz + s2y * cz * sx + s2z * cx * sy);
      float t2 = 0.5 * (c2x * c2y + c2y * c2z + c2z * c2x);
      return t1 - t2 + 0.15;
    } else {
      // Neovius
      return 3.0 * (cx + cy + cz) + 4.0 * cx * cy * cz;
    }
  }

  void main() {
    vec3 p = vWorldPosition;
    float nodalVal = evalTpms(p);

    // Modulate local thickness based on stress factor
    float effectiveThickness = uWallThickness * (1.0 + uStressFactor * 1.5);
    float halfThickness = effectiveThickness * 0.5;
    float dist = abs(nodalVal) - halfThickness;

    // Solid color (cyan/teal for TPMS lattice) vs Void background (dark slate with alpha)
    vec3 solidColor = vec3(0.08, 0.72, 0.83);
    vec3 voidColor = vec3(0.12, 0.14, 0.18);
    vec3 borderColor = vec3(0.95, 0.98, 1.0);

    // Antialiased border around level set
    float aa = fwidth(dist);
    float inside = 1.0 - smoothstep(-aa, aa, dist);

    // Iso-contour lines
    float contour = 0.0;
    if (uShowContours) {
      float contourDist = mod(abs(dist), uContourSpacing);
      contour = 1.0 - smoothstep(0.0, aa * 2.0, min(contourDist, uContourSpacing - contourDist));
    }

    vec3 finalColor = mix(voidColor, solidColor, inside);
    finalColor = mix(finalColor, borderColor, contour * 0.7);

    float alpha = inside > 0.5 ? 0.92 : 0.45;
    gl_FragColor = vec4(finalColor, alpha);
  }
`;

export function createCrossSectionPlane(size = 80.0): { mesh: THREE.Mesh; uniforms: CrossSectionUniforms } {
  const geometry = new THREE.PlaneGeometry(size, size, 64, 64);
  geometry.rotateX(-Math.PI / 2); // default horizontal XY-slice at height Z

  const uniforms: CrossSectionUniforms = {
    uCellSize: { value: 10.0 },
    uWallThickness: { value: 1.0 },
    uTpmsType: { value: 0 },
    uPlaneElevation: { value: 0.0 },
    uShowContours: { value: true },
    uContourSpacing: { value: 0.5 },
    uStressFactor: { value: 0.0 },
  };

  const material = new THREE.ShaderMaterial({
    vertexShader,
    fragmentShader,
    uniforms: uniforms as any,
    transparent: true,
    side: THREE.DoubleSide,
    depthWrite: false,
  });

  const mesh = new THREE.Mesh(geometry, material);
  mesh.name = 'tpms-cross-section-plane';
  return { mesh, uniforms };
}
