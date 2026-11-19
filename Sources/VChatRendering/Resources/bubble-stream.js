// Same keyed DOM-diff approach as desktop VChat, confined to one sandboxed bubble.
(() => {
    const mount = document.createElement('div');
    mount.dataset.vcpIslandHost = '';
    document.body.appendChild(mount);
    let previousChildren = [];
    function sealedRoot(source) {
        // Desktop V5 starts animations only after the outer div is sealed. A
        // closing div inside a script, comment, quoted attribute or style is not a seal.
        if (source.length > 256 * 1024) return false;
        const tags = /<!--[\s\S]*?(?:-->|$)|<(script|style|textarea)\b(?:"[^"]*"|'[^']*'|[^'">])*>[\s\S]*?(?:<\/\1\s*>|$)|<(\/?)(div)\b(?:"[^"]*"|'[^']*'|[^'">])*>/gi;
        let depth = 0, seen = false;
        for (const t of source.matchAll(tags)) {
            if (!t[3]) continue;
            if (t[2]) { if (--depth === 0) return seen; }
            else { depth++; seen = true; }
        }
        return false;
    }
    const executed = new WeakMap();
    const epoch = window.VCPBubbleEpoch;
    let pending, frame, lifecycleStarted = false, lifecycleDelivered = false;
    // Model scripts run in the page world, while the renderer stays isolated.
    // Deliver their normal document-ready lifecycle once, after the final frame.
    function pageLifecycle(finish) {
        const bridge = document.createElement('script');
        bridge.textContent = `(() => {
            const key=Symbol.for('vcp.island.lifecycle');
            const state=window[key]||(window[key]={original:Object.getOwnPropertyDescriptor(document,'readyState'),done:false});
            if(state.done)return;
            if(!${finish}){Object.defineProperty(document,'readyState',{configurable:true,get:()=> 'loading'});return;}
            state.done=true;
            if(state.original)Object.defineProperty(document,'readyState',state.original);else delete document.readyState;
            document.dispatchEvent(new Event('DOMContentLoaded',{bubbles:true}));
            const images=Array.from(document.images).filter(image=>!image.complete);
            Promise.all(images.map(image=>new Promise(resolve=>{
                image.addEventListener('load',resolve,{once:true});image.addEventListener('error',resolve,{once:true});
            }))).then(()=>window.dispatchEvent(new Event('load')));
        })()`;
        document.head.appendChild(bridge); bridge.remove();
    }
    function apply() {
        frame = undefined;
        if (!pending) return;
        const {source,streaming} = pending; pending = undefined;
        // Parse in an inert document. Detached elements owned by the live document
        // start fetching as soon as innerHTML sets src, even if morphdom keeps the old IMG.
        const inert = document.implementation.createHTMLDocument('');
        const next = inert.createElement('div');
        next.innerHTML = source;
        VCPBubbleMarkdown(next);
        for (const img of next.querySelectorAll('img[src]')) {
            const src = img.getAttribute('src');
            let decoded;
            try { decoded = decodeURIComponent(src); } catch { decoded = src; }
            const relativeSticker = !/^[a-z][a-z0-9+.-]*:/i.test(src) && decoded.includes('表情包') && !src.startsWith('//');
            if (/^https:\/\//i.test(src) || relativeSticker) {
                // Keep responsive images native to WebKit when the author supplies a srcset.
                if (!img.hasAttribute('srcset') && !img.closest('picture'))
                    img.setAttribute('src', 'vchat-image://asset?' + encodeURIComponent(src));
            }
        }
        // Keep live state (e.g. a canvas or a counter mutated by an early
        // script) on unchanged top-level authored nodes across append and terminal.
        const children = Array.from(next.children, n => n.outerHTML);
        const stable = new WeakSet();
        Array.from(mount.children).forEach((node,i) => {
            const record = previousChildren[i];
            if (record && record.node === node && record.html === children[i]) stable.add(node);
        });
        morphdom(mount,next,{
            childrenOnly: true,
            getNodeKey: node => node.id || node.dataset?.vcpKey,
            onBeforeElUpdated: (from,to) => {
                if (stable.has(from) || from.isEqualNode(to)) return false;
                if (from.tagName === 'SCRIPT' && executed.get(from) === JSON.stringify([to.type, to.textContent])) return false;
                if (from.tagName === 'DETAILS') to.open = from.open;
                if (from === document.activeElement && 'value' in from) to.value = from.value;
                return true;
            }
        });
        VCPBubbleMarkdown.colorize(mount);
        // A partial <script> is parsed inertly. Activate only fully received
        // inline scripts, once; further text chunks keep the same live nodes.
        const closed = new Set();
        const pattern = /<script\b(?:"[^"]*"|'[^']*'|[^'">])*>[\s\S]*?<\/script\s*>/gi;
        for (const match of source.matchAll(pattern)) {
            const template = document.createElement('template'); template.innerHTML = match[0];
            const script = template.content.querySelector('script');
            if (script) closed.add(script.textContent);
        }
        if (!lifecycleStarted) { pageLifecycle(false); lifecycleStarted = true; }
        const sealed = !streaming || sealedRoot(source);
        const desktopCard = !mount.querySelector('#vcp-root');
        for (const script of mount.querySelectorAll('script')) {
            if (!sealed) continue;
            const key = JSON.stringify([script.type,script.textContent]);
            if (script.src || !closed.has(script.textContent) || executed.get(script) === key) continue;
            const active = document.createElement('script');
            for (const attribute of script.attributes) active.setAttribute(attribute.name,attribute.value);
            // Desktop animation scripts receive a container *outside* their card,
            // so container.querySelector can select the outer card itself.
            const classic = !script.type || /^(text|application)\/javascript$/i.test(script.type);
            active.textContent = desktopCard && classic
                ? '(function(container){\n' + script.textContent + '\n}).call(window,document.currentScript.closest("[data-vcp-island-host]"));'
                : script.textContent;
            executed.set(active,key); script.replaceWith(active);
        }
        previousChildren = Array.from(mount.children,(node,i) => ({node, html:children[i]}));
        if (!streaming && !lifecycleDelivered) { pageLifecycle(true); lifecycleDelivered = true; }
    }
    window.VCPBubbleStream = {
        update(source,streaming,requestEpoch) {
            if (requestEpoch !== epoch) return;
            pending = {source,streaming};
            if (!streaming) { if (frame !== undefined) cancelAnimationFrame(frame); apply(); }
            else if (frame === undefined) frame = requestAnimationFrame(apply);
        }
    };
})();
