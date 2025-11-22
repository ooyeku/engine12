// Collapsible component for expandable/collapsible sections
(function() {
    'use strict';
    
    let initialized = false;
    
    function initializeCollapsibles() {
        // Prevent double initialization
        if (initialized) return;
        initialized = true;
        
        const headers = document.querySelectorAll('[data-collapsible-header]');
        
        headers.forEach((header, index) => {
            // Skip if already initialized
            if (header.dataset.collapsibleInitialized === 'true') return;
            header.dataset.collapsibleInitialized = 'true';
            
            const targetId = header.getAttribute('data-collapsible-target');
            const target = targetId ? document.getElementById(targetId) : header.nextElementSibling;
            
            if (!target) return;
            
            // Set initial state
            const isCollapsed = header.dataset.collapsibleCollapsed !== 'false';
            target.style.display = isCollapsed ? 'none' : 'block';
            updateHeaderIcon(header, isCollapsed);
            
            // Add click handler
            header.addEventListener('click', function(e) {
                e.preventDefault();
                toggleCollapsible(header, target);
            });
        });
    }
    
    function toggleCollapsible(header, target) {
        const isCollapsed = target.style.display === 'none' || !target.style.display;
        
        if (isCollapsed) {
            target.style.display = 'block';
            header.dataset.collapsibleCollapsed = 'false';
        } else {
            target.style.display = 'none';
            header.dataset.collapsibleCollapsed = 'true';
        }
        
        updateHeaderIcon(header, !isCollapsed);
    }
    
    function updateHeaderIcon(header, isCollapsed) {
        const icon = header.querySelector('[data-collapsible-icon]');
        if (icon) {
            icon.textContent = isCollapsed ? '▼' : '▲';
        } else {
            // If no icon element, update first text node or add icon
            const text = header.textContent.trim();
            if (text.startsWith('▼') || text.startsWith('▲')) {
                header.textContent = (isCollapsed ? '▼' : '▲') + ' ' + text.substring(1).trim();
            }
        }
    }
    
    // Initialize on DOM ready
    if (document.readyState === 'loading') {
        document.addEventListener('DOMContentLoaded', initializeCollapsibles);
    } else {
        // DOM already loaded
        initializeCollapsibles();
    }
    
    // Export for manual initialization if needed
    window.Collapsible = {
        init: initializeCollapsibles,
        toggle: function(headerId) {
            const header = document.querySelector(`[data-collapsible-header="${headerId}"]`);
            if (header) {
                const targetId = header.getAttribute('data-collapsible-target');
                const target = targetId ? document.getElementById(targetId) : header.nextElementSibling;
                if (target) {
                    toggleCollapsible(header, target);
                }
            }
        }
    };
})();

