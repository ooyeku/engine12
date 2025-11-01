const API_BASE = '/api/todos';

let todos = [];
let currentFilter = 'all';

// API Functions
async function fetchTodos() {
    try {
        const response = await fetch(API_BASE);
        if (!response.ok) throw new Error('Failed to fetch todos');
        const data = await response.json();
        // API returns array directly, not wrapped in object
        todos = Array.isArray(data) ? data : [];
        renderTodos();
        updateStats();
    } catch (error) {
        showError('Failed to load todos: ' + error.message);
    }
}

async function createTodo(title, description) {
    try {
        const response = await fetch(API_BASE, {
            method: 'POST',
            headers: {
                'Content-Type': 'application/json',
            },
            body: JSON.stringify({ title, description }),
        });
        if (!response.ok) {
            const error = await response.json();
            throw new Error(error.error || 'Failed to create todo');
        }
        const data = await response.json();
        // API returns todo directly, not wrapped
        const todo = data.todo || data;
        todos.push(todo);
        renderTodos();
        updateStats();
        return todo;
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
        });
        if (!response.ok) {
            const error = await response.json();
            throw new Error(error.error || 'Failed to update todo');
        }
        const data = await response.json();
        const todo = data.todo || data;
        const index = todos.findIndex(t => t.id === id);
        if (index !== -1) {
            todos[index] = todo;
        }
        renderTodos();
        updateStats();
        return todo;
    } catch (error) {
        showError('Failed to update todo: ' + error.message);
        throw error;
    }
}

async function deleteTodo(id) {
    try {
        const response = await fetch(`${API_BASE}/${id}`, {
            method: 'DELETE',
        });
        if (!response.ok) {
            const error = await response.json();
            throw new Error(error.error || 'Failed to delete todo');
        }
        todos = todos.filter(t => t.id !== id);
        renderTodos();
        updateStats();
    } catch (error) {
        showError('Failed to delete todo: ' + error.message);
    }
}

async function fetchStats() {
    try {
        const response = await fetch(`${API_BASE}/stats`);
        if (!response.ok) throw new Error('Failed to fetch stats');
        const data = await response.json();
        // API returns stats directly or wrapped in stats property
        const stats = data.stats || data;
        updateStatsFromData(stats);
    } catch (error) {
        console.error('Failed to fetch stats:', error);
    }
}

// DOM Functions
function renderTodos() {
    const todoList = document.getElementById('todo-list');
    const filteredTodos = getFilteredTodos();

    if (filteredTodos.length === 0) {
        todoList.innerHTML = '<div class="empty-state"><p>No tasks match your filter.</p></div>';
        return;
    }

    todoList.innerHTML = filteredTodos.map(todo => `
        <div class="todo-item ${todo.completed ? 'completed' : ''}" data-id="${todo.id}">
            <div class="todo-header">
                <input 
                    type="checkbox" 
                    class="todo-checkbox" 
                    ${todo.completed ? 'checked' : ''}
                    onchange="toggleTodo(${todo.id})"
                >
                <div class="todo-title">${escapeHtml(todo.title)}</div>
            </div>
            ${todo.description ? `<div class="todo-description">${escapeHtml(todo.description)}</div>` : ''}
            <div class="todo-meta">
                <span>Created: ${formatDate(todo.created_at)}</span>
                <div class="todo-actions">
                    <button onclick="editTodo(${todo.id})">Edit</button>
                    <button class="btn-delete" onclick="deleteTodo(${todo.id})">Delete</button>
                </div>
            </div>
        </div>
    `).join('');
}

function getFilteredTodos() {
    switch (currentFilter) {
        case 'completed':
            return todos.filter(t => t.completed);
        case 'pending':
            return todos.filter(t => !t.completed);
        default:
            return todos;
    }
}

function updateStats() {
    const total = todos.length;
    const completed = todos.filter(t => t.completed).length;
    const pending = total - completed;
    const progress = total > 0 ? Math.round((completed / total) * 100) : 0;

    document.getElementById('stat-total').textContent = total;
    document.getElementById('stat-pending').textContent = pending;
    document.getElementById('stat-completed').textContent = completed;
    document.getElementById('stat-progress').textContent = progress + '%';
}

function updateStatsFromData(stats) {
    document.getElementById('stat-total').textContent = stats.total || 0;
    document.getElementById('stat-pending').textContent = stats.pending || 0;
    document.getElementById('stat-completed').textContent = stats.completed || 0;
    document.getElementById('stat-progress').textContent = (stats.completed_percentage || 0).toFixed(0) + '%';
}

function toggleTodo(id) {
    const todo = todos.find(t => t.id === id);
    if (todo) {
        updateTodo(id, { completed: !todo.completed });
    }
}

function editTodo(id) {
    const todo = todos.find(t => t.id === id);
    if (!todo) return;

    const newTitle = prompt('Enter new title:', todo.title);
    if (newTitle === null) return;

    const newDescription = prompt('Enter new description:', todo.description || '');
    if (newDescription === null) return;

    const updates = {};
    if (newTitle !== todo.title) updates.title = newTitle;
    if (newDescription !== (todo.description || '')) updates.description = newDescription;

    if (Object.keys(updates).length > 0) {
        updateTodo(id, updates);
    }
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
    const date = new Date(timestamp);
    return date.toLocaleDateString() + ' ' + date.toLocaleTimeString([], { hour: '2-digit', minute: '2-digit' });
}

// Event Listeners
document.addEventListener('DOMContentLoaded', () => {
    // Add todo button
    document.getElementById('add-todo-btn').addEventListener('click', async () => {
        const titleInput = document.getElementById('todo-title');
        const descInput = document.getElementById('todo-description');
        
        const title = titleInput.value.trim();
        if (!title) {
            showError('Title is required');
            return;
        }

        const description = descInput.value.trim();
        
        try {
            await createTodo(title, description);
            titleInput.value = '';
            descInput.value = '';
        } catch (error) {
            // Error already shown in createTodo
        }
    });

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

    // Initial load
    fetchTodos();
    fetchStats();

    // Refresh stats periodically
    setInterval(fetchStats, 30000); // Every 30 seconds
});

