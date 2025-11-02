const API_BASE = '/api/todos';

let todos = [];
let currentFilter = 'all';
let currentSort = 'created_desc';
let searchQuery = '';

// API Functions
async function fetchTodos() {
    try {
        const response = await fetch(API_BASE, {
            cache: 'no-store',
        });
        if (!response.ok) throw new Error('Failed to fetch todos');
        const data = await response.json();
        todos = Array.isArray(data) ? data : [];
        renderTodos();
        updateStats();
    } catch (error) {
        showError('Failed to load todos: ' + error.message);
    }
}

async function createTodo(title, description, priority = 'medium', dueDate = null, tags = []) {
    try {
        const response = await fetch(API_BASE, {
            method: 'POST',
            headers: {
                'Content-Type': 'application/json',
            },
            body: JSON.stringify({ 
                title, 
                description,
                priority,
                due_date: dueDate ? new Date(dueDate).getTime() : null,
                tags: Array.isArray(tags) ? tags.join(',') : tags
            }),
            cache: 'no-store',
        });
        if (!response.ok) {
            const error = await response.json();
            throw new Error(error.error || 'Failed to create todo');
        }
        await response.json();
        await fetchTodos();
        await fetchStats();
        return null;
    } catch (error) {
        showError('Failed to create todo: ' + error.message);
        throw error;
    }
}

async function updateTodo(id, updates) {
    try {
        const response = await fetch(`${API_BASE}/${id}`, {
            method: 'PUT',
            headers: {
                'Content-Type': 'application/json',
            },
            body: JSON.stringify(updates),
            cache: 'no-store',
        });
        if (!response.ok) {
            const error = await response.json();
            throw new Error(error.error || 'Failed to update todo');
        }
        await response.json();
        await fetchTodos();
        await fetchStats();
        return null;
    } catch (error) {
        showError('Failed to update todo: ' + error.message);
        throw error;
    }
}

async function deleteTodo(id) {
    try {
        const response = await fetch(`${API_BASE}/${id}`, {
            method: 'DELETE',
            cache: 'no-store',
        });
        
        if (!response.ok) {
            const error = await response.json();
            throw new Error(error.error || 'Failed to delete todo');
        }
        
        await response.json();
        await fetchTodos();
        await fetchStats();
    } catch (error) {
        showError('Failed to delete todo: ' + error.message);
    }
}

async function fetchStats() {
    try {
        const response = await fetch(`${API_BASE}/stats`, {
            cache: 'no-store',
        });
        if (!response.ok) throw new Error('Failed to fetch stats');
        const data = await response.json();
        const stats = data.stats || data;
        updateStatsFromData(stats);
    } catch (error) {
        console.error('Failed to fetch stats:', error);
    }
}

// DOM Functions
function renderTodos() {
    const todoList = document.getElementById('todo-list');
    let filteredTodos = getFilteredTodos();
    filteredTodos = applySearch(filteredTodos);
    filteredTodos = applySort(filteredTodos);

    if (filteredTodos.length === 0) {
        todoList.innerHTML = '<div class="empty-state"><p>No tasks match your filter.</p></div>';
        return;
    }

    todoList.innerHTML = filteredTodos.map(todo => {
        const isOverdue = todo.due_date && new Date(parseInt(todo.due_date)) < new Date() && !todo.completed;
        const priorityClass = `priority-${todo.priority || 'medium'}`;
        const tags = todo.tags ? todo.tags.split(',').map(t => t.trim()).filter(Boolean) : [];
        
        return `
            <div class="todo-item ${todo.completed ? 'completed' : ''} ${priorityClass} ${isOverdue ? 'overdue' : ''}" data-id="${todo.id}">
                <div class="todo-header">
                    <input 
                        type="checkbox" 
                        class="todo-checkbox" 
                        ${todo.completed ? 'checked' : ''}
                        onchange="toggleTodo(${todo.id})"
                    >
                    <div class="todo-title-wrapper">
                        <div class="todo-title">${escapeHtml(todo.title)}</div>
                        ${todo.priority && todo.priority !== 'medium' ? `
                            <span class="priority-badge priority-${todo.priority}">${todo.priority}</span>
                        ` : ''}
                    </div>
                </div>
                ${todo.description ? `<div class="todo-description">${escapeHtml(todo.description)}</div>` : ''}
                ${tags.length > 0 ? `
                    <div class="todo-tags">
                        ${tags.map(tag => `<span class="tag">${escapeHtml(tag)}</span>`).join('')}
                    </div>
                ` : ''}
                <div class="todo-meta">
                    <div class="todo-dates">
                        ${todo.due_date ? `
                            <span class="due-date ${isOverdue ? 'overdue' : ''}">
                                Due: ${formatDate(parseInt(todo.due_date))}
                            </span>
                        ` : ''}
                        <span>Created: ${formatDate(todo.created_at)}</span>
                    </div>
                    <div class="todo-actions">
                        <button onclick="editTodo(${todo.id})">Edit</button>
                        <button class="btn-delete" onclick="confirmDelete(${todo.id})">Delete</button>
                    </div>
                </div>
            </div>
        `;
    }).join('');
}

function getFilteredTodos() {
    let filtered = todos;
    
    switch (currentFilter) {
        case 'completed':
            return filtered.filter(t => t.completed);
        case 'pending':
            return filtered.filter(t => !t.completed);
        case 'overdue':
            const now = new Date();
            return filtered.filter(t => 
                t.due_date && new Date(parseInt(t.due_date)) < now && !t.completed
            );
        case 'high-priority':
            return filtered.filter(t => t.priority === 'high' && !t.completed);
        default:
            return filtered;
    }
}

function applySearch(todos) {
    if (!searchQuery.trim()) return todos;
    const query = searchQuery.toLowerCase();
    return todos.filter(todo => 
        todo.title.toLowerCase().includes(query) ||
        (todo.description && todo.description.toLowerCase().includes(query)) ||
        (todo.tags && todo.tags.toLowerCase().includes(query))
    );
}

function applySort(todos) {
    return [...todos].sort((a, b) => {
        switch (currentSort) {
            case 'created_desc':
                return (b.created_at || 0) - (a.created_at || 0);
            case 'created_asc':
                return (a.created_at || 0) - (b.created_at || 0);
            case 'title_asc':
                return (a.title || '').localeCompare(b.title || '');
            case 'title_desc':
                return (b.title || '').localeCompare(a.title || '');
            case 'priority_desc':
                const priorityOrder = { high: 3, medium: 2, low: 1 };
                return (priorityOrder[b.priority] || 0) - (priorityOrder[a.priority] || 0);
            case 'priority_asc':
                const priorityOrderAsc = { high: 3, medium: 2, low: 1 };
                return (priorityOrderAsc[a.priority] || 0) - (priorityOrderAsc[b.priority] || 0);
            case 'due_asc':
                const dueA = a.due_date ? parseInt(a.due_date) : 0;
                const dueB = b.due_date ? parseInt(b.due_date) : 0;
                return dueA - dueB;
            case 'due_desc':
                const dueA2 = a.due_date ? parseInt(a.due_date) : 0;
                const dueB2 = b.due_date ? parseInt(b.due_date) : 0;
                return dueB2 - dueA2;
            default:
                return 0;
        }
    });
}

function updateStats() {
    const total = todos.length;
    const completed = todos.filter(t => t.completed).length;
    const pending = total - completed;
    const progress = total > 0 ? Math.round((completed / total) * 100) : 0;
    const now = new Date();
    const overdue = todos.filter(t => 
        t.due_date && new Date(parseInt(t.due_date)) < now && !t.completed
    ).length;

    document.getElementById('stat-total').textContent = total;
    document.getElementById('stat-pending').textContent = pending;
    document.getElementById('stat-completed').textContent = completed;
    document.getElementById('stat-progress').textContent = progress + '%';
    document.getElementById('stat-overdue').textContent = overdue;
}

function updateStatsFromData(stats) {
    document.getElementById('stat-total').textContent = stats.total || 0;
    document.getElementById('stat-pending').textContent = stats.pending || 0;
    document.getElementById('stat-completed').textContent = stats.completed || 0;
    document.getElementById('stat-progress').textContent = (stats.completed_percentage || 0).toFixed(0) + '%';
    document.getElementById('stat-overdue').textContent = stats.overdue || 0;
}

function toggleTodo(id) {
    const todo = todos.find(t => t.id === id);
    if (todo) {
        updateTodo(id, { completed: !todo.completed });
    }
}

function confirmDelete(id) {
    const todo = todos.find(t => t.id === id);
    if (!todo) return;
    if (confirm(`Are you sure you want to delete "${todo.title}"?`)) {
        deleteTodo(id);
    }
}

function editTodo(id) {
    const todo = todos.find(t => t.id === id);
    if (!todo) return;

    const newTitle = prompt('Enter new title:', todo.title);
    if (newTitle === null) return;

    const newDescription = prompt('Enter new description:', todo.description || '');
    if (newDescription === null) return;

    const newPriority = prompt('Enter priority (low/medium/high):', todo.priority || 'medium');
    if (newPriority === null) return;

    const updates = {};
    if (newTitle !== todo.title) updates.title = newTitle;
    if (newDescription !== (todo.description || '')) updates.description = newDescription;
    if (newPriority !== (todo.priority || 'medium')) updates.priority = newPriority;

    if (Object.keys(updates).length > 0) {
        updateTodo(id, updates);
    }
}

function exportTodos() {
    const dataStr = JSON.stringify(todos, null, 2);
    const dataBlob = new Blob([dataStr], { type: 'application/json' });
    const url = URL.createObjectURL(dataBlob);
    const link = document.createElement('a');
    link.href = url;
    link.download = `todos-${new Date().toISOString().split('T')[0]}.json`;
    link.click();
    URL.revokeObjectURL(url);
}

function showError(message) {
    const errorEl = document.getElementById('error-message');
    errorEl.textContent = message;
    errorEl.classList.add('show');
    setTimeout(() => {
        errorEl.classList.remove('show');
    }, 5000);
}

function escapeHtml(text) {
    const div = document.createElement('div');
    div.textContent = text;
    return div.innerHTML;
}

function formatDate(timestamp) {
    if (!timestamp) return '';
    const date = new Date(parseInt(timestamp));
    return date.toLocaleDateString() + ' ' + date.toLocaleTimeString([], { hour: '2-digit', minute: '2-digit' });
}

// Event Listeners
document.addEventListener('DOMContentLoaded', () => {
    // Add todo button
    document.getElementById('add-todo-btn').addEventListener('click', async () => {
        const titleInput = document.getElementById('todo-title');
        const descInput = document.getElementById('todo-description');
        const prioritySelect = document.getElementById('todo-priority');
        const dueDateInput = document.getElementById('todo-due-date');
        const tagsInput = document.getElementById('todo-tags');
        
        const title = titleInput.value.trim();
        if (!title) {
            showError('Title is required');
            return;
        }

        const description = descInput.value.trim();
        const priority = prioritySelect.value;
        const dueDate = dueDateInput.value || null;
        const tags = tagsInput.value.split(',').map(t => t.trim()).filter(Boolean);
        
        try {
            await createTodo(title, description, priority, dueDate, tags);
            titleInput.value = '';
            descInput.value = '';
            dueDateInput.value = '';
            tagsInput.value = '';
            prioritySelect.value = 'medium';
        } catch (error) {
            // Error already shown
        }
    });

    // Search
    const searchInput = document.getElementById('search-input');
    const clearSearch = document.getElementById('clear-search');
    searchInput.addEventListener('input', (e) => {
        searchQuery = e.target.value;
        clearSearch.style.display = searchQuery ? 'block' : 'none';
        renderTodos();
    });
    clearSearch.addEventListener('click', () => {
        searchInput.value = '';
        searchQuery = '';
        clearSearch.style.display = 'none';
        renderTodos();
    });

    // Sort
    document.getElementById('sort-select').addEventListener('change', (e) => {
        currentSort = e.target.value;
        renderTodos();
    });

    // Export
    document.getElementById('export-btn').addEventListener('click', exportTodos);

    // Enter key support
    document.getElementById('todo-title').addEventListener('keypress', (e) => {
        if (e.key === 'Enter') {
            document.getElementById('add-todo-btn').click();
        }
    });

    // Filter buttons
    document.querySelectorAll('.filter-btn').forEach(btn => {
        btn.addEventListener('click', () => {
            document.querySelectorAll('.filter-btn').forEach(b => b.classList.remove('active'));
            btn.classList.add('active');
            currentFilter = btn.dataset.filter;
            renderTodos();
        });
    });

    // Keyboard shortcuts
    document.addEventListener('keydown', (e) => {
        if (e.ctrlKey || e.metaKey) {
            if (e.key === 'k') {
                e.preventDefault();
                searchInput.focus();
            } else if (e.key === 'n') {
                e.preventDefault();
                document.getElementById('todo-title').focus();
            }
        }
    });

    // Initial load
    fetchTodos();
    fetchStats();

    // Refresh stats periodically
    setInterval(fetchStats, 30000);
});
