const API_BASE = '/api/todos';
const AUTH_BASE = '/auth';

let todos = [];
let currentFilter = 'all';
let currentSort = 'created_desc';
let searchQuery = '';
let currentPage = 'dashboard';
let completedSearchQuery = '';
let currentUser = null;

// Authentication Functions
function getAuthToken() {
    return localStorage.getItem('auth_token');
}

function setAuthToken(token) {
    if (token) {
        localStorage.setItem('auth_token', token);
    } else {
        localStorage.removeItem('auth_token');
    }
}

function isAuthenticated() {
    return getAuthToken() !== null;
}

function getAuthHeaders() {
    const headers = {
        'Content-Type': 'application/json',
    };
    const token = getAuthToken();
    if (token) {
        headers['Authorization'] = `Bearer ${token}`;
    }
    return headers;
}

async function login(username, password) {
    try {
        const response = await fetch(`${AUTH_BASE}/login`, {
            method: 'POST',
            headers: {
                'Content-Type': 'application/json',
            },
            body: JSON.stringify({ username, password }),
        });
        
        if (!response.ok) {
            const errorText = await response.text().catch(() => 'Login failed');
            console.error('[Login] Error response:', response.status, errorText);
            let error;
            try {
                error = JSON.parse(errorText);
            } catch {
                error = { error: errorText || 'Login failed' };
            }
            throw new Error(error.error || 'Login failed');
        }
        
        const responseText = await response.text();
        console.log('[Login] Response text:', responseText);
        const data = JSON.parse(responseText);
        console.log('[Login] Parsed data:', data);
        
        if (data.token) {
            setAuthToken(data.token);
            currentUser = data.user;
            updateAuthUI();
            return true;
        }
        console.error('[Login] No token in response:', data);
        throw new Error('No token received');
    } catch (error) {
        showAuthError(error.message);
        return false;
    }
}

async function signup(username, email, password) {
    try {
        const response = await fetch(`${AUTH_BASE}/register`, {
            method: 'POST',
            headers: {
                'Content-Type': 'application/json',
            },
            body: JSON.stringify({ username, email, password }),
        });
        
        if (!response.ok) {
            const error = await response.json().catch(() => ({ error: 'Signup failed' }));
            throw new Error(error.error || 'Signup failed');
        }
        
        // After signup, automatically log in
        return await login(username, password);
    } catch (error) {
        showAuthError(error.message);
        return false;
    }
}

async function logout() {
    try {
        await fetch(`${AUTH_BASE}/logout`, {
            method: 'POST',
            headers: getAuthHeaders(),
        });
    } catch (error) {
        console.error('Logout error:', error);
    } finally {
        setAuthToken(null);
        currentUser = null;
        updateAuthUI();
        todos = [];
    }
}

async function checkAuth() {
    const token = getAuthToken();
    if (!token) {
        updateAuthUI();
        return false;
    }
    
    try {
        const response = await fetch(`${AUTH_BASE}/me`, {
            headers: getAuthHeaders(),
        });
        
        if (!response.ok) {
            setAuthToken(null);
            currentUser = null;
            updateAuthUI();
            return false;
        }
        
        const data = await response.json();
        currentUser = data.user || data;
        updateAuthUI();
        return true;
    } catch (error) {
        console.error('Auth check error:', error);
        setAuthToken(null);
        currentUser = null;
        updateAuthUI();
        return false;
    }
}

function updateAuthUI() {
    const authFormContainer = document.getElementById('auth-form-container');
    const userInfoContainer = document.getElementById('user-info-container');
    const mainNav = document.getElementById('main-nav');
    const mainContent = document.getElementById('main-content');
    const userUsername = document.getElementById('user-username');
    
    if (isAuthenticated() && currentUser) {
        // Show user info, hide login form
        authFormContainer.style.display = 'none';
        userInfoContainer.style.display = 'block';
        mainNav.style.display = 'flex';
        mainContent.style.display = 'block';
        if (userUsername) {
            userUsername.textContent = currentUser.username || 'User';
        }
    } else {
        // Show login form, hide user info and main content
        authFormContainer.style.display = 'block';
        userInfoContainer.style.display = 'none';
        mainNav.style.display = 'none';
        mainContent.style.display = 'none';
    }
}

function showAuthError(message) {
    const errorDiv = document.getElementById('auth-error');
    if (errorDiv) {
        errorDiv.textContent = message;
        errorDiv.style.display = 'block';
        setTimeout(() => {
            errorDiv.style.display = 'none';
        }, 5000);
    }
}

// API Functions
async function fetchTodos() {
    if (!isAuthenticated()) {
        return;
    }
    try {
        const response = await fetch(API_BASE, {
            headers: getAuthHeaders(),
            cache: 'no-store',
        });
        if (response.status === 401) {
            await logout();
            return;
        }
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
    if (!isAuthenticated()) {
        return;
    }
    try {
        const bodyData = { 
            title, 
            description,
            priority,
            due_date: dueDate ? new Date(dueDate).getTime() : null,
            tags: Array.isArray(tags) ? tags.join(',') : tags
        };
        const bodyString = JSON.stringify(bodyData);
        console.log('[createTodo] Sending POST request with body:', bodyString);
        console.log('[createTodo] Body length:', bodyString.length);
        console.log('[createTodo] Headers:', getAuthHeaders());
        
        const response = await fetch(API_BASE, {
            method: 'POST',
            headers: getAuthHeaders(),
            body: bodyString,
            cache: 'no-store',
        });
        
        const responseText = await response.text();
        console.log('[createTodo] Response status:', response.status);
        console.log('[createTodo] Response text:', responseText);
        
        if (response.status === 401) {
            await logout();
            return;
        }
        if (!response.ok) {
            let error;
            try {
                error = JSON.parse(responseText);
            } catch {
                error = { error: responseText || 'Failed to create todo' };
            }
            console.error('[createTodo] Error response:', error);
            throw new Error(error.error || 'Failed to create todo');
        }
        try {
            await JSON.parse(responseText);
        } catch (e) {
            console.warn('[createTodo] Failed to parse response as JSON:', responseText);
        }
        await fetchTodos();
        await fetchStats();
        return null;
    } catch (error) {
        showError('Failed to create todo: ' + error.message);
        throw error;
    }
}

async function updateTodo(id, updates) {
    if (!isAuthenticated()) {
        return;
    }
    try {
        const response = await fetch(`${API_BASE}/${id}`, {
            method: 'PUT',
            headers: getAuthHeaders(),
            body: JSON.stringify(updates),
            cache: 'no-store',
        });
        if (response.status === 401) {
            await logout();
            return;
        }
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
    if (!isAuthenticated()) {
        return;
    }
    try {
        const response = await fetch(`${API_BASE}/${id}`, {
            method: 'DELETE',
            headers: getAuthHeaders(),
            cache: 'no-store',
        });
        
        if (response.status === 401) {
            await logout();
            return;
        }
        
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
    if (!isAuthenticated()) {
        return;
    }
    try {
        const response = await fetch(`${API_BASE}/stats`, {
            headers: getAuthHeaders(),
            cache: 'no-store',
        });
        if (response.status === 401) {
            await logout();
            return;
        }
        if (!response.ok) throw new Error('Failed to fetch stats');
        const data = await response.json();
        const stats = data.stats || data;
        updateStatsFromData(stats);
    } catch (error) {
        console.error('Failed to fetch stats:', error);
    }
}

// Page Management Functions
function switchPage(pageName) {
    currentPage = pageName;
    
    // Update URL hash
    window.location.hash = pageName;
    
    // Update tab buttons
    document.querySelectorAll('.tab-btn').forEach(btn => {
        if (btn.dataset.page === pageName) {
            btn.classList.add('active');
        } else {
            btn.classList.remove('active');
        }
    });
    
    // Update page containers
    document.querySelectorAll('.page-container').forEach(container => {
        if (container.dataset.page === pageName) {
            container.classList.add('active');
        } else {
            container.classList.remove('active');
        }
    });
    
    // Refresh content based on page
    switch (pageName) {
        case 'dashboard':
            renderDashboard();
            break;
        case 'active':
            renderTodos();
            break;
        case 'completed':
            renderCompletedTodos();
            break;
        case 'analytics':
            renderAnalytics();
            break;
    }
}

function initializePageFromHash() {
    const hash = window.location.hash.substring(1);
    const validPages = ['dashboard', 'active', 'completed', 'analytics'];
    if (hash && validPages.includes(hash)) {
        switchPage(hash);
    } else {
        switchPage('dashboard');
    }
}

// DOM Functions
function renderTodos() {
    const todoList = document.getElementById('todo-list');
    let filteredTodos = getFilteredTodos();
    
    // On the Active page, always exclude completed todos
    if (currentPage === 'active') {
        filteredTodos = filteredTodos.filter(t => !t.completed);
    }
    
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

function applySort(todos, sortValue = null) {
    const sort = sortValue || currentSort;
    return [...todos].sort((a, b) => {
        switch (sort) {
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

// Dashboard Rendering
function renderDashboard() {
    updateStats();
}

// Completed Todos Rendering
function renderCompletedTodos() {
    const completedList = document.getElementById('completed-todo-list');
    let completedTodos = todos.filter(t => t.completed);
    
    // Apply search
    if (completedSearchQuery.trim()) {
        const query = completedSearchQuery.toLowerCase();
        completedTodos = completedTodos.filter(todo => 
            todo.title.toLowerCase().includes(query) ||
            (todo.description && todo.description.toLowerCase().includes(query)) ||
            (todo.tags && todo.tags.toLowerCase().includes(query))
        );
    }
    
    // Apply sort
    const sortSelect = document.getElementById('sort-select-completed');
    if (sortSelect) {
        const sortValue = sortSelect.value;
        completedTodos = applySort(completedTodos, sortValue);
    }
    
    if (completedTodos.length === 0) {
        completedList.innerHTML = '<div class="empty-state"><p>No completed tasks yet.</p></div>';
        return;
    }
    
    completedList.innerHTML = completedTodos.map(todo => {
        const priorityClass = `priority-${todo.priority || 'medium'}`;
        const tags = todo.tags ? todo.tags.split(',').map(t => t.trim()).filter(Boolean) : [];
        
        return `
            <div class="todo-item completed ${priorityClass}" data-id="${todo.id}">
                <div class="todo-header">
                    <input 
                        type="checkbox" 
                        class="todo-checkbox" 
                        checked
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
                        <span>Completed: ${formatDate(todo.updated_at || todo.created_at)}</span>
                    </div>
                    <div class="todo-actions">
                        <button class="btn-delete" onclick="confirmDelete(${todo.id})">Delete</button>
                    </div>
                </div>
            </div>
        `;
    }).join('');
}

// Analytics Rendering
function renderAnalytics() {
    updateAnalyticsStats();
    renderPriorityChart();
    renderStatusChart();
    renderTagsChart();
    renderTrendsChart();
}

function updateAnalyticsStats() {
    const total = todos.length;
    const completed = todos.filter(t => t.completed).length;
    const pending = total - completed;
    const progress = total > 0 ? Math.round((completed / total) * 100) : 0;
    const now = new Date();
    const overdue = todos.filter(t => 
        t.due_date && new Date(parseInt(t.due_date)) < now && !t.completed
    ).length;

    document.getElementById('analytics-stat-total').textContent = total;
    document.getElementById('analytics-stat-pending').textContent = pending;
    document.getElementById('analytics-stat-completed').textContent = completed;
    document.getElementById('analytics-stat-progress').textContent = progress + '%';
    document.getElementById('analytics-stat-overdue').textContent = overdue;
}

function renderPriorityChart() {
    const priorityChart = document.getElementById('priority-chart');
    const high = todos.filter(t => t.priority === 'high' && !t.completed).length;
    const medium = todos.filter(t => t.priority === 'medium' && !t.completed).length;
    const low = todos.filter(t => t.priority === 'low' && !t.completed).length;
    const total = high + medium + low;
    
    if (total === 0) {
        priorityChart.innerHTML = '<p style="color: var(--text-secondary); text-align: center;">No active tasks</p>';
        return;
    }
    
    priorityChart.innerHTML = `
        <div class="chart-bar">
            <span class="chart-label">High</span>
            <div class="chart-bar-container">
                <div class="chart-bar-fill priority-high" style="width: ${(high / total) * 100}%">
                    <span class="chart-bar-value">${high}</span>
                </div>
            </div>
        </div>
        <div class="chart-bar">
            <span class="chart-label">Medium</span>
            <div class="chart-bar-container">
                <div class="chart-bar-fill priority-medium" style="width: ${(medium / total) * 100}%">
                    <span class="chart-bar-value">${medium}</span>
                </div>
            </div>
        </div>
        <div class="chart-bar">
            <span class="chart-label">Low</span>
            <div class="chart-bar-container">
                <div class="chart-bar-fill priority-low" style="width: ${(low / total) * 100}%">
                    <span class="chart-bar-value">${low}</span>
                </div>
            </div>
        </div>
    `;
}

function renderStatusChart() {
    const statusChart = document.getElementById('status-chart');
    const completed = todos.filter(t => t.completed).length;
    const pending = todos.filter(t => !t.completed).length;
    const total = todos.length;
    
    if (total === 0) {
        statusChart.innerHTML = '<p style="color: var(--text-secondary); text-align: center;">No tasks yet</p>';
        return;
    }
    
    statusChart.innerHTML = `
        <div class="chart-bar">
            <span class="chart-label">Completed</span>
            <div class="chart-bar-container">
                <div class="chart-bar-fill" style="width: ${(completed / total) * 100}%; background: linear-gradient(90deg, var(--success), #6ee7b7);">
                    <span class="chart-bar-value">${completed}</span>
                </div>
            </div>
        </div>
        <div class="chart-bar">
            <span class="chart-label">Pending</span>
            <div class="chart-bar-container">
                <div class="chart-bar-fill" style="width: ${(pending / total) * 100}%">
                    <span class="chart-bar-value">${pending}</span>
                </div>
            </div>
        </div>
    `;
}

function renderTagsChart() {
    const tagsChart = document.getElementById('tags-chart');
    const tagCounts = {};
    
    todos.forEach(todo => {
        if (todo.tags) {
            const tags = todo.tags.split(',').map(t => t.trim()).filter(Boolean);
            tags.forEach(tag => {
                tagCounts[tag] = (tagCounts[tag] || 0) + 1;
            });
        }
    });
    
    const sortedTags = Object.entries(tagCounts)
        .sort((a, b) => b[1] - a[1])
        .slice(0, 5);
    
    if (sortedTags.length === 0) {
        tagsChart.innerHTML = '<p style="color: var(--text-secondary); text-align: center;">No tags used</p>';
        return;
    }
    
    const maxCount = sortedTags[0][1];
    tagsChart.innerHTML = sortedTags.map(([tag, count]) => `
        <div class="chart-bar">
            <span class="chart-label">${escapeHtml(tag)}</span>
            <div class="chart-bar-container">
                <div class="chart-bar-fill" style="width: ${(count / maxCount) * 100}%">
                    <span class="chart-bar-value">${count}</span>
                </div>
            </div>
        </div>
    `).join('');
}

function renderTrendsChart() {
    const trendsChart = document.getElementById('trends-chart');
    const completedToday = todos.filter(t => {
        if (!t.completed || !t.updated_at) return false;
        const today = new Date();
        const todoDate = new Date(t.updated_at);
        return todoDate.toDateString() === today.toDateString();
    }).length;
    
    const completedThisWeek = todos.filter(t => {
        if (!t.completed || !t.updated_at) return false;
        const weekAgo = new Date();
        weekAgo.setDate(weekAgo.getDate() - 7);
        return new Date(t.updated_at) >= weekAgo;
    }).length;
    
    const completedThisMonth = todos.filter(t => {
        if (!t.completed || !t.updated_at) return false;
        const monthAgo = new Date();
        monthAgo.setMonth(monthAgo.getMonth() - 1);
        return new Date(t.updated_at) >= monthAgo;
    }).length;
    
    const maxCount = Math.max(completedToday, completedThisWeek, completedThisMonth, 1);
    
    trendsChart.innerHTML = `
        <div class="chart-bar">
            <span class="chart-label">Today</span>
            <div class="chart-bar-container">
                <div class="chart-bar-fill" style="width: ${(completedToday / maxCount) * 100}%">
                    <span class="chart-bar-value">${completedToday}</span>
                </div>
            </div>
        </div>
        <div class="chart-bar">
            <span class="chart-label">This Week</span>
            <div class="chart-bar-container">
                <div class="chart-bar-fill" style="width: ${(completedThisWeek / maxCount) * 100}%">
                    <span class="chart-bar-value">${completedThisWeek}</span>
                </div>
            </div>
        </div>
        <div class="chart-bar">
            <span class="chart-label">This Month</span>
            <div class="chart-bar-container">
                <div class="chart-bar-fill" style="width: ${(completedThisMonth / maxCount) * 100}%">
                    <span class="chart-bar-value">${completedThisMonth}</span>
                </div>
            </div>
        </div>
    `;
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
document.addEventListener('DOMContentLoaded', async () => {
    // Initialize authentication
    await checkAuth();
    
    // Auth form event listeners
    const loginBtn = document.getElementById('login-btn');
    const signupBtn = document.getElementById('signup-btn');
    const toggleSignupBtn = document.getElementById('toggle-signup-btn');
    const toggleLoginBtn = document.getElementById('toggle-login-btn');
    const logoutBtn = document.getElementById('logout-btn');
    const authUsername = document.getElementById('auth-username');
    const authEmail = document.getElementById('auth-email');
    const authPassword = document.getElementById('auth-password');
    
    let isSignupMode = false;
    
    function toggleSignupMode() {
        isSignupMode = !isSignupMode;
        authEmail.style.display = isSignupMode ? 'block' : 'none';
        loginBtn.style.display = isSignupMode ? 'none' : 'block';
        signupBtn.style.display = isSignupMode ? 'block' : 'none';
        toggleSignupBtn.style.display = isSignupMode ? 'none' : 'block';
        toggleLoginBtn.style.display = isSignupMode ? 'block' : 'none';
        
        // Clear any error messages when switching modes
        showAuthError('');
        
        // Focus on email field when entering signup mode
        if (isSignupMode && authEmail) {
            authEmail.focus();
        }
    }
    
    if (toggleSignupBtn) {
        toggleSignupBtn.addEventListener('click', toggleSignupMode);
    }
    if (toggleLoginBtn) {
        toggleLoginBtn.addEventListener('click', toggleSignupMode);
    }
    
    if (loginBtn) {
        loginBtn.addEventListener('click', async () => {
            const username = authUsername.value.trim();
            const password = authPassword.value;
            if (!username || !password) {
                showAuthError('Username and password are required');
                return;
            }
            const success = await login(username, password);
            if (success) {
                authUsername.value = '';
                authPassword.value = '';
                await fetchTodos();
                await fetchStats();
            }
        });
    }
    
    if (signupBtn) {
        signupBtn.addEventListener('click', async () => {
            // If not in signup mode yet, toggle to signup mode first
            if (!isSignupMode) {
                toggleSignupMode();
                return;
            }
            
            // Now in signup mode, proceed with signup
            const username = authUsername.value.trim();
            const email = authEmail.value.trim();
            const password = authPassword.value;
            if (!username || !email || !password) {
                showAuthError('Username, email, and password are required');
                return;
            }
            const success = await signup(username, email, password);
            if (success) {
                authUsername.value = '';
                authEmail.value = '';
                authPassword.value = '';
                await fetchTodos();
                await fetchStats();
            }
        });
    }
    
    if (logoutBtn) {
        logoutBtn.addEventListener('click', async () => {
            await logout();
        });
    }
    
    // Allow Enter key to submit auth forms
    if (authPassword) {
        authPassword.addEventListener('keypress', (e) => {
            if (e.key === 'Enter') {
                if (isSignupMode && signupBtn) {
                    signupBtn.click();
                } else if (loginBtn) {
                    loginBtn.click();
                }
            }
        });
    }
    
    // Tab switching
    document.querySelectorAll('.tab-btn').forEach(btn => {
        btn.addEventListener('click', () => {
            switchPage(btn.dataset.page);
        });
    });

    // Hash change listener for back/forward navigation
    window.addEventListener('hashchange', initializePageFromHash);


    // Toggle form functionality - Active Tasks page
    const toggleFormBtn = document.getElementById('toggle-form-btn');
    const todoForm = document.getElementById('todo-form');
    const cancelFormBtn = document.getElementById('cancel-form-btn');
    const toggleFormIcon = document.getElementById('toggle-form-icon');
    const toggleFormText = document.getElementById('toggle-form-text');

    function showForm(formId, titleId, iconId, textId) {
        const form = document.getElementById(formId);
        const icon = document.getElementById(iconId);
        const text = document.getElementById(textId);
        if (form && icon && text) {
            form.style.display = 'block';
            icon.textContent = '−';
            text.textContent = 'Cancel';
            document.getElementById(titleId).focus();
        }
    }

    function hideForm(formId, titleId, descId, dateId, tagsId, priorityId, iconId, textId) {
        const form = document.getElementById(formId);
        const icon = document.getElementById(iconId);
        const text = document.getElementById(textId);
        if (form && icon && text) {
            form.style.display = 'none';
            icon.textContent = '+';
            text.textContent = 'Add New Task';
            // Clear form
            document.getElementById(titleId).value = '';
            document.getElementById(descId).value = '';
            document.getElementById(dateId).value = '';
            document.getElementById(tagsId).value = '';
            document.getElementById(priorityId).value = 'medium';
        }
    }

    // Active Tasks page form
    if (toggleFormBtn && todoForm) {
        toggleFormBtn.addEventListener('click', () => {
            if (todoForm.style.display === 'none' || !todoForm.style.display) {
                showForm('todo-form', 'todo-title', 'toggle-form-icon', 'toggle-form-text');
            } else {
                hideForm('todo-form', 'todo-title', 'todo-description', 'todo-due-date', 'todo-tags', 'todo-priority', 'toggle-form-icon', 'toggle-form-text');
            }
        });

        if (cancelFormBtn) {
            cancelFormBtn.addEventListener('click', () => {
                hideForm('todo-form', 'todo-title', 'todo-description', 'todo-due-date', 'todo-tags', 'todo-priority', 'toggle-form-icon', 'toggle-form-text');
            });
        }
    }

    // Dashboard page form
    const dashboardToggleFormBtn = document.getElementById('dashboard-toggle-form-btn');
    const dashboardTodoForm = document.getElementById('dashboard-todo-form');
    const dashboardCancelFormBtn = document.getElementById('dashboard-cancel-form-btn');

    if (dashboardToggleFormBtn && dashboardTodoForm) {
        dashboardToggleFormBtn.addEventListener('click', () => {
            if (dashboardTodoForm.style.display === 'none' || !dashboardTodoForm.style.display) {
                showForm('dashboard-todo-form', 'dashboard-todo-title', 'dashboard-toggle-form-icon', 'dashboard-toggle-form-text');
            } else {
                hideForm('dashboard-todo-form', 'dashboard-todo-title', 'dashboard-todo-description', 'dashboard-todo-due-date', 'dashboard-todo-tags', 'dashboard-todo-priority', 'dashboard-toggle-form-icon', 'dashboard-toggle-form-text');
            }
        });

        if (dashboardCancelFormBtn) {
            dashboardCancelFormBtn.addEventListener('click', () => {
                hideForm('dashboard-todo-form', 'dashboard-todo-title', 'dashboard-todo-description', 'dashboard-todo-due-date', 'dashboard-todo-tags', 'dashboard-todo-priority', 'dashboard-toggle-form-icon', 'dashboard-toggle-form-text');
            });
        }
    }

    // Helper function to handle todo creation
    async function handleCreateTodo(titleId, descId, priorityId, dateId, tagsId, formId, iconId, textId) {
        const titleInput = document.getElementById(titleId);
        const descInput = document.getElementById(descId);
        const prioritySelect = document.getElementById(priorityId);
        const dueDateInput = document.getElementById(dateId);
        const tagsInput = document.getElementById(tagsId);
        
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
            hideForm(formId, titleId, descId, dateId, tagsId, priorityId, iconId, textId);
        } catch (error) {
            // Error already shown
        }
    }

    // Add todo button (Active page)
    const addTodoBtn = document.getElementById('add-todo-btn');
    if (addTodoBtn) {
        addTodoBtn.addEventListener('click', async () => {
            await handleCreateTodo('todo-title', 'todo-description', 'todo-priority', 'todo-due-date', 'todo-tags', 'todo-form', 'toggle-form-icon', 'toggle-form-text');
        });
    }

    // Add todo button (Dashboard page)
    const dashboardAddTodoBtn = document.getElementById('dashboard-add-todo-btn');
    if (dashboardAddTodoBtn) {
        dashboardAddTodoBtn.addEventListener('click', async () => {
            await handleCreateTodo('dashboard-todo-title', 'dashboard-todo-description', 'dashboard-todo-priority', 'dashboard-todo-due-date', 'dashboard-todo-tags', 'dashboard-todo-form', 'dashboard-toggle-form-icon', 'dashboard-toggle-form-text');
        });
    }

    // Search (Active page)
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

    // Search (Completed page)
    const searchInputCompleted = document.getElementById('search-input-completed');
    const clearSearchCompleted = document.getElementById('clear-search-completed');
    if (searchInputCompleted && clearSearchCompleted) {
        searchInputCompleted.addEventListener('input', (e) => {
            completedSearchQuery = e.target.value;
            clearSearchCompleted.style.display = completedSearchQuery ? 'block' : 'none';
            renderCompletedTodos();
        });
        clearSearchCompleted.addEventListener('click', () => {
            searchInputCompleted.value = '';
            completedSearchQuery = '';
            clearSearchCompleted.style.display = 'none';
            renderCompletedTodos();
        });
    }

    // Sort (Active page)
    document.getElementById('sort-select').addEventListener('change', (e) => {
        currentSort = e.target.value;
        renderTodos();
    });

    // Sort (Completed page)
    const sortSelectCompleted = document.getElementById('sort-select-completed');
    if (sortSelectCompleted) {
        sortSelectCompleted.addEventListener('change', () => {
            renderCompletedTodos();
        });
    }

    // Export
    document.getElementById('export-btn').addEventListener('click', exportTodos);

    // Bulk actions (Completed page)
    const deleteAllBtn = document.getElementById('delete-all-completed');
    const restoreAllBtn = document.getElementById('restore-all-completed');
    if (deleteAllBtn) {
        deleteAllBtn.addEventListener('click', async () => {
            const completedTodos = todos.filter(t => t.completed);
            if (completedTodos.length === 0) {
                showError('No completed tasks to delete');
                return;
            }
            if (confirm(`Delete all ${completedTodos.length} completed tasks?`)) {
                for (const todo of completedTodos) {
                    await deleteTodo(todo.id);
                }
            }
        });
    }
    if (restoreAllBtn) {
        restoreAllBtn.addEventListener('click', async () => {
            const completedTodos = todos.filter(t => t.completed);
            if (completedTodos.length === 0) {
                showError('No completed tasks to restore');
                return;
            }
            if (confirm(`Restore all ${completedTodos.length} completed tasks?`)) {
                for (const todo of completedTodos) {
                    await updateTodo(todo.id, { completed: false });
                }
            }
        });
    }

    // Enter key support - Active Tasks page
    const todoTitleInput = document.getElementById('todo-title');
    if (todoTitleInput) {
        todoTitleInput.addEventListener('keypress', (e) => {
            if (e.key === 'Enter') {
                document.getElementById('add-todo-btn').click();
            }
        });
    }

    // Enter key support - Dashboard page
    const dashboardTodoTitleInput = document.getElementById('dashboard-todo-title');
    if (dashboardTodoTitleInput) {
        dashboardTodoTitleInput.addEventListener('keypress', (e) => {
            if (e.key === 'Enter') {
                document.getElementById('dashboard-add-todo-btn').click();
            }
        });
    }

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
                if (currentPage === 'active') {
                    searchInput.focus();
                } else if (currentPage === 'completed' && searchInputCompleted) {
                    searchInputCompleted.focus();
                }
            } else if (e.key === 'n') {
                e.preventDefault();
                if (currentPage === 'active') {
                    const form = document.getElementById('todo-form');
                    if (form && (form.style.display === 'none' || !form.style.display)) {
                        showForm('todo-form', 'todo-title', 'toggle-form-icon', 'toggle-form-text');
                    } else {
                        document.getElementById('todo-title').focus();
                    }
                } else if (currentPage === 'dashboard') {
                    const form = document.getElementById('dashboard-todo-form');
                    if (form && (form.style.display === 'none' || !form.style.display)) {
                        showForm('dashboard-todo-form', 'dashboard-todo-title', 'dashboard-toggle-form-icon', 'dashboard-toggle-form-text');
                    } else {
                        document.getElementById('dashboard-todo-title').focus();
                    }
                }
            } else if (e.key === '1') {
                e.preventDefault();
                switchPage('dashboard');
            } else if (e.key === '2') {
                e.preventDefault();
                switchPage('active');
            } else if (e.key === '3') {
                e.preventDefault();
                switchPage('completed');
            } else if (e.key === '4') {
                e.preventDefault();
                switchPage('analytics');
            }
        }
    });

    // Initial load (only if authenticated)
    if (isAuthenticated()) {
        fetchTodos();
        fetchStats();
        initializePageFromHash();
        
        // Refresh stats periodically
        setInterval(fetchStats, 30000);
    }
});
