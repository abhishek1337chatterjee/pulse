/* pulse internals — shared sidebar nav + scrollspy + copy buttons.
 * Each spoke HTML page declares its identity via:
 *     <body data-page="claude-stats">
 * and provides an empty placeholder:
 *     <nav class="toc" id="toc"></nav>
 * This script renders the sidebar from the PAGES table below, marking the
 * current spoke and the in-page sections (anchored from <section id="…">).
 *
 * Loaded over file:// — no network, no fetch, just DOM.
 */

const PAGES = [
    {
        id: 'home',
        title: 'overview',
        href: 'index.html',
        sections: [
            { id: 'overview',     label: 'What is pulse' },
            { id: 'architecture', label: 'Architecture' },
        ],
    },
    {
        id: 'claude-stats',
        title: 'claude-stats',
        href: 'claude-stats.html',
        sections: [
            { id: 'cli',             label: 'CLI commands' },
            { id: 'ingest-daily',    label: 'Daily cost ingest' },
            { id: 'ingest-sessions', label: 'Session ingest' },
            { id: 'dashboard',       label: 'Dashboard build' },
            { id: 'schema',          label: 'Schema' },
        ],
    },
    {
        id: 'battery-stats',
        title: 'battery-stats',
        href: 'battery-stats.html',
        sections: [
            { id: 'cli',       label: 'CLI commands' },
            { id: 'poll',      label: 'Poller (5 min)' },
            { id: 'aggregate', label: 'Aggregator' },
            { id: 'upower',    label: 'UPower import' },
            { id: 'powertop',  label: 'PowerTop snapshots' },
            { id: 'schema',    label: 'Schema' },
        ],
    },
    {
        id: 'internals',
        title: 'cross-cutting',
        href: 'internals.html',
        sections: [
            { id: 'schedule', label: 'systemd timers' },
            { id: 'timezone', label: 'Timezone gotcha' },
            { id: 'filemap',  label: 'File map' },
        ],
    },
    {
        id: 'walkthrough',
        title: 'walkthrough',
        href: 'walkthrough.html',
        sections: [
            { id: 'flow',              label: 'Data flow' },
            { id: 'shape',             label: 'The shared shape' },
            { id: 'cs-ingest-daily',   label: 'cs · ingest-daily.sh' },
            { id: 'cs-ingest-sessions',label: 'cs · ingest-sessions.py' },
            { id: 'cs-schema',         label: 'cs · schema.sql' },
            { id: 'cs-cleanup',        label: 'cs · cleanup-old.sh' },
            { id: 'cs-dashboard',      label: 'cs · build-dashboard.sh' },
            { id: 'bs-poll',           label: 'bs · poll.sh' },
            { id: 'bs-aggregate',      label: 'bs · aggregate-daily.sh' },
            { id: 'bs-upower',         label: 'bs · ingest-upower.sh' },
            { id: 'bs-powertop',       label: 'bs · powertop-capture.sh' },
            { id: 'bs-schema',         label: 'bs · schema.sql' },
            { id: 'crosscut',          label: 'Cross-cutting patterns' },
        ],
    },
];

(function () {
    const currentId = document.body.dataset.page || 'home';
    const toc = document.getElementById('toc');
    if (!toc) return;

    // Brand row links to home regardless of current page
    const brand = document.createElement('a');
    brand.className = 'brand';
    brand.href = 'index.html';
    brand.innerHTML = '<div class="dot"></div><h1>pulse internals</h1>';
    toc.appendChild(brand);

    // Sidebar groups: one per spoke. Current spoke shows section anchors;
    // other spokes show just a single clickable title.
    PAGES.forEach(page => {
        const group = document.createElement('div');
        group.className = 'group';
        const isCurrent = page.id === currentId;

        const label = document.createElement('a');
        label.className = 'page-link' + (isCurrent ? ' current' : '');
        label.href = page.href;
        label.textContent = page.title;
        group.appendChild(label);
        toc.appendChild(group);

        if (isCurrent && page.sections.length) {
            page.sections.forEach(s => {
                const a = document.createElement('a');
                a.className = 'section';
                a.href = '#' + s.id;
                a.textContent = s.label;
                a.dataset.target = s.id;
                toc.appendChild(a);
            });
        }
    });

    // Scrollspy for in-page section anchors
    const sectionLinks = Array.from(toc.querySelectorAll('a.section'));
    const sections = sectionLinks
        .map(a => document.getElementById(a.dataset.target))
        .filter(Boolean);
    const linkBySection = new Map(sections.map((s, i) => [s, sectionLinks[i]]));

    if ('IntersectionObserver' in window && sections.length) {
        const visible = new Set();
        const obs = new IntersectionObserver(entries => {
            entries.forEach(e => {
                if (e.isIntersecting) visible.add(e.target);
                else visible.delete(e.target);
            });
            const ordered = sections.filter(s => visible.has(s));
            if (ordered.length) {
                sectionLinks.forEach(l => l.classList.remove('active'));
                linkBySection.get(ordered[0]).classList.add('active');
            }
        }, { rootMargin: '-10% 0px -70% 0px', threshold: 0 });
        sections.forEach(s => obs.observe(s));
    }

    // Copy buttons on every <pre>
    document.querySelectorAll('pre').forEach(pre => {
        const btn = document.createElement('button');
        btn.className = 'copy';
        btn.textContent = 'copy';
        btn.addEventListener('click', () => {
            const code = pre.querySelector('code') || pre;
            navigator.clipboard.writeText(code.innerText).then(() => {
                btn.textContent = 'copied';
                btn.classList.add('copied');
                setTimeout(() => {
                    btn.textContent = 'copy';
                    btn.classList.remove('copied');
                }, 1200);
            }).catch(() => {
                btn.textContent = 'failed';
                setTimeout(() => { btn.textContent = 'copy'; }, 1200);
            });
        });
        pre.appendChild(btn);
    });
})();
