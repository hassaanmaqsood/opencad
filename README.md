# OpenCAD Distribution Branch (`dist`)

This branch contains zero-account, production-ready distribution artifacts for OpenCAD.

## 1. Web Component (Zero-Code HTML Embedding)
```html
<script type="module" src="https://cdn.jsdelivr.net/gh/hassaanmaqsood/opencad@dist/opencad-element.mjs"></script>
<opencad-viewer template="cnc-bracket" sliders="true" height="500px"></opencad-viewer>
```

## 2. ESM CDN Import
```javascript
import { OpenCadCore } from 'https://cdn.jsdelivr.net/gh/hassaanmaqsood/opencad@dist/opencad.mjs';
const cad = await OpenCadCore.create();
const box = cad.createBox(50, 30, 10);
```

## 3. Node.js / Bun Git Install
```bash
npm install github:hassaanmaqsood/opencad#dist
```

## 4. Python Git Install
```bash
pip install "git+https://github.com/hassaanmaqsood/opencad.git@dist#subdirectory=python"
```

## 5. Rust Git Dependency
```bash
cargo add opencad --git https://github.com/hassaanmaqsood/opencad --branch dist
```
