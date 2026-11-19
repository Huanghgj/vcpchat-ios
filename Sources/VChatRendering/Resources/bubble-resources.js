// Run inside the bubble's isolated renderer. Never persist authored pages or scripts.
// Rewriting before insertion avoids a redundant remote fetch; the scoped image CSP
// also covers the brief interval before the observer processes a script-created node.
(() => {
    const imageScheme = 'vchat-image://asset?', videoScheme = 'vchat-image://movie?';
    const remote = value => /^https:\/\//i.test(value);
    function asset(value, movie = false) {
        const url = value.trim();
        if (!remote(url)) {
            if (movie || /^(?:[a-z][a-z0-9+.-]*:|\/\/)/i.test(url)) return value;
            try { if (!decodeURIComponent(url).includes('表情包')) return value; } catch { return value; }
        }
        if (movie && !/\.(mp4|m4v|mov|webm|ogv)(?:[?#]|$)/i.test(url)) return value;
        return (movie ? videoScheme : imageScheme) + encodeURIComponent(url);
    }
    function candidates(value) {
        // A URL token may itself contain commas (e.g. data:). Only a trailing
        // separator or the comma following a descriptor separates candidates.
        let result='', i=0;
        while (i<value.length) {
            while (i<value.length && /[\s,]/.test(value[i])) result += value[i++];
            let j=i;
            while (j<value.length && !/\s/.test(value[j])) j++;
            const url=value.slice(i,j);
            if (!url) break;
            const raw=url.replace(/,+$/, '');
            result += asset(raw) + url.slice(raw.length); i=j;
            if (raw.length===url.length) {
                while (i<value.length && value[i]!==',') result += value[i++];
            }
        }
        return result;
    }
    function styles(text) {
        return text.replace(/url\(\s*(?:"([^"]*)"|'([^']*)'|([^\s)'"]+))\s*\)/gi, (all, a, b, c) => {
            const src = a ?? b ?? c, target = asset(src);
            return src === target ? all : 'url("' + target + '")';
        });
    }
    function element(el) {
        if (el.nodeType !== 1) return;
        const set = (name, fn) => {
            const v = el.getAttribute(name);
            if (v != null) { const next = fn(v); if (next !== v) el.setAttribute(name, next); }
        };
        const tag = el.localName;
        if (tag === 'img') { set('src', asset); set('srcset', candidates); }
        if (tag === 'image') { set('href', asset); set('xlink:href', asset); }
        if (tag === 'source') {
            if (el.parentElement?.localName === 'picture') set('srcset', candidates);
            if (el.parentElement?.localName === 'video') set('src', x => asset(x, true));
        }
        if (tag === 'video') {
            set('poster', asset); set('src', x => asset(x, true));
            if (!el.hasAttribute('preload') && !el.hasAttribute('autoplay')) el.preload = 'none';
        }
        set('style', styles);
        if (tag === 'style') {
            const old = el.textContent, next = styles(old);
            if (old !== next) el.textContent = next;
        }
    }
    const select = 'img,source,video,image,style,[style]';
    const walk = root => { element(root); root.querySelectorAll?.(select).forEach(element); };
    window.vcpTopicResources = { walk, watch(root) {
        const observer = new MutationObserver(records => {
            for (const r of records) {
                if (r.type === 'attributes') element(r.target);
                else if (r.target.parentElement?.localName === 'style') element(r.target.parentElement);
                else if (r.target.localName === 'style') element(r.target);
                else r.addedNodes.forEach(walk);
            }
        });
        observer.observe(root, {subtree:true,childList:true,characterData:true,attributes:true,
            attributeFilter:['src','srcset','style','poster','href','xlink:href']});
    }};
})();
