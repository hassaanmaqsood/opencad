export var CadImplicitOpcode;
(function (CadImplicitOpcode) {
    CadImplicitOpcode[CadImplicitOpcode["PRIMITIVE"] = 0] = "PRIMITIVE";
    CadImplicitOpcode[CadImplicitOpcode["BREP_DISTANCE"] = 1] = "BREP_DISTANCE";
    CadImplicitOpcode[CadImplicitOpcode["TPMS_GYROID"] = 2] = "TPMS_GYROID";
    CadImplicitOpcode[CadImplicitOpcode["TPMS_SCHWARZ_P"] = 3] = "TPMS_SCHWARZ_P";
    CadImplicitOpcode[CadImplicitOpcode["TPMS_DIAMOND"] = 4] = "TPMS_DIAMOND";
    CadImplicitOpcode[CadImplicitOpcode["STRESS_FIELD_MODULATE"] = 5] = "STRESS_FIELD_MODULATE";
    CadImplicitOpcode[CadImplicitOpcode["SMOOTH_UNION"] = 6] = "SMOOTH_UNION";
    CadImplicitOpcode[CadImplicitOpcode["SMOOTH_INTERSECT"] = 7] = "SMOOTH_INTERSECT";
    CadImplicitOpcode[CadImplicitOpcode["SMOOTH_DIFFERENCE"] = 8] = "SMOOTH_DIFFERENCE";
    CadImplicitOpcode[CadImplicitOpcode["SHELL"] = 9] = "SHELL";
    CadImplicitOpcode[CadImplicitOpcode["OFFSET"] = 10] = "OFFSET";
    CadImplicitOpcode[CadImplicitOpcode["WARP"] = 11] = "WARP";
})(CadImplicitOpcode || (CadImplicitOpcode = {}));
export var CadImplicitPrimType;
(function (CadImplicitPrimType) {
    CadImplicitPrimType[CadImplicitPrimType["SPHERE"] = 0] = "SPHERE";
    CadImplicitPrimType[CadImplicitPrimType["BOX"] = 1] = "BOX";
    CadImplicitPrimType[CadImplicitPrimType["CYLINDER"] = 2] = "CYLINDER";
    CadImplicitPrimType[CadImplicitPrimType["TORUS"] = 3] = "TORUS";
    CadImplicitPrimType[CadImplicitPrimType["PLANE"] = 4] = "PLANE";
})(CadImplicitPrimType || (CadImplicitPrimType = {}));
export var CadImplicitWarpType;
(function (CadImplicitWarpType) {
    CadImplicitWarpType[CadImplicitWarpType["TWIST"] = 0] = "TWIST";
    CadImplicitWarpType[CadImplicitWarpType["TAPER"] = 1] = "TAPER";
    CadImplicitWarpType[CadImplicitWarpType["BEND"] = 2] = "BEND";
})(CadImplicitWarpType || (CadImplicitWarpType = {}));
//# sourceMappingURL=types.js.map