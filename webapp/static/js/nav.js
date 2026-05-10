// Single source of truth for the global top navigation.
//
// Usage:
//   <div id="nav-mount" data-active="topologies"></div>
//   <script src="/static/js/nav.js"></script>
//
// The data-active value selects which link gets the .active class.
// Allowed values: "dashboard", "simulations", "topologies", "interactive",
// or omit / unknown for none.
//
// Pages with a bespoke local header (topology_editor.html, topology_creator.html)
// place the mount div FIRST so the global nav stacks above the local toolbar;
// CSS already gives .navbar { flex-shrink: 0 } so column-flex bodies stay tidy.

(function () {
  const LINKS = [
    { key: 'dashboard',    href: '/static/index.html',        label: 'Dashboard' },
    { key: 'simulations',  href: '/static/simulations.html',  label: 'Simulations' },
    { key: 'topologies',   href: '/static/topologies.html',   label: 'Topologies' },
    { key: 'interactive',  href: '/static/interactive.html',  label: 'Interactive REPL' },
  ];

  function buildNav(active) {
    const liHtml = LINKS.map(l => {
      const cls = l.key === active ? ' class="active"' : '';
      return '<li><a href="' + l.href + '"' + cls + '>' + l.label + '</a></li>';
    }).join('');
    return (
      '<nav class="navbar">' +
        '<a href="/static/index.html" class="brand" style="text-decoration:none">' +
          'lora-universal-simulator' +
        '</a>' +
        '<ul class="nav-links">' + liHtml + '</ul>' +
        '<span class="spacer"></span>' +
      '</nav>'
    );
  }

  function init() {
    const mount = document.getElementById('nav-mount');
    if (!mount) return;
    const active = mount.getAttribute('data-active') || '';
    mount.outerHTML = buildNav(active);
  }

  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', init);
  } else {
    init();
  }
})();
