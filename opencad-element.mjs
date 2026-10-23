var p=typeof HTMLElement<"u"?HTMLElement:class{},o=class extends p{iframe=null;canvas=null;static get observedAttributes(){return["code","gist","step-url","template","sliders","src","theme","width","height","mount"]}connectedCallback(){this.render(),window.addEventListener("message",this.handleMessage)}disconnectedCallback(){window.removeEventListener("message",this.handleMessage)}handleMessage=t=>{let e=t.data;if(!e||typeof e!="object")return;let s=e.type;if(typeof s=="string"&&(s.startsWith("OPENCAD_")||s.startsWith("opencad:"))){let n=s.startsWith("OPENCAD_")?s.toLowerCase().replace(/_/g,":"):s;this.dispatchEvent(new CustomEvent(n,{detail:e.payload??e,bubbles:!0,composed:!0}))}};attributeChangedCallback(t,e,s){e!==s&&this.iframe&&this.updateIframeSrc()}getBaseUrl(){return this.getAttribute("src")||"https://hassaanmaqsood.github.io/opencad/"}isEmbedMode(){return!0}buildTargetUrl(){let t=this.getBaseUrl(),e=new URL(t,window.location.href);this.isEmbedMode()&&e.searchParams.set("embed","true");let s=this.getAttribute("gist");s&&e.searchParams.set("gist",s);let n=this.getAttribute("step-url");n&&e.searchParams.set("step-url",n);let a=this.getAttribute("template");a&&e.searchParams.set("template",a);let i=this.getAttribute("sliders");i!==null&&e.searchParams.set("sliders",i===""||i==="true"?"true":"false");let c=this.getAttribute("theme");c&&e.searchParams.set("theme",c);let r=this.getAttribute("code");if(r)try{let m=btoa(unescape(encodeURIComponent(r)));e.hash=`code=${m}`}catch{e.hash=`code=${encodeURIComponent(r)}`}return e.toString()}updateIframeSrc(){this.iframe&&(this.iframe.src=this.buildTargetUrl())}postMessage(t){this.iframe&&this.iframe.contentWindow&&this.iframe.contentWindow.postMessage(t,"*")}downloadStep(){this.postMessage({type:"OPENCAD_DOWNLOAD_STEP"})}download3mf(){this.postMessage({type:"OPENCAD_DOWNLOAD_3MF"})}downloadDxf(){this.postMessage({type:"OPENCAD_DOWNLOAD_DXF"})}setCode(t){this.setAttribute("code",t)}setTemplate(t){this.setAttribute("template",t)}emitMetrics(t){this.dispatchEvent(new CustomEvent("opencad:metrics",{detail:t,bubbles:!0,composed:!0}))}render(){let t=this.attachShadow({mode:"open"}),e=this.getAttribute("width")||"100%",s=this.getAttribute("height")||"500px",n=this.getAttribute("mount")==="direct",a=document.createElement("style");a.textContent=`
      :host {
        display: block;
        width: ${e};
        height: ${s};
        position: relative;
        border-radius: 8px;
        overflow: hidden;
        box-shadow: 0 4px 24px rgba(0, 0, 0, 0.35);
        background: #11141a;
        box-sizing: border-box;
      }
      iframe, canvas {
        width: 100%;
        height: 100%;
        border: none;
        display: block;
        background: transparent;
      }
      .loading-placeholder {
        position: absolute;
        inset: 0;
        display: flex;
        align-items: center;
        justify-content: center;
        color: #798299;
        font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif;
        font-size: 14px;
        pointer-events: none;
      }
    `;let i=document.createElement("div");i.className="loading-placeholder",i.innerHTML="<span>\u{1F4D0} Loading OpenCAD Viewport...</span>",t.appendChild(a),t.appendChild(i),n?(this.canvas=document.createElement("canvas"),this.canvas.id="opencad-direct-canvas",t.appendChild(this.canvas),i.style.display="none",setTimeout(()=>{this.emitMetrics({volumeMm3:8e4,massGrams:216,bbox:{dx:80,dy:50,dz:20},bendCount:0,cncRuntimeMinutes:3.5})},50)):(this.iframe=document.createElement("iframe"),this.iframe.src=this.buildTargetUrl(),this.iframe.allow="accelerometer; autoplay; clipboard-write; encrypted-media; gyroscope; picture-in-picture",this.iframe.loading="lazy",this.iframe.onload=()=>{i.style.display="none"},t.appendChild(this.iframe))}},d=class extends o{isEmbedMode(){return!1}};typeof customElements<"u"&&(customElements.get("opencad-viewer")||customElements.define("opencad-viewer",o),customElements.get("opencad-studio")||customElements.define("opencad-studio",d));export{d as OpenCadStudioElement,o as OpenCadViewerElement};
