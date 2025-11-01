const std = @import("std");
const Request = @import("request.zig").Request;
const Response = @import("response.zig").Response;

/// Validation error for a specific field
pub const FieldError = struct {
    field: []const u8,
    message: []const u8,
    code: []const u8,
};

/// Collection of validation errors
pub const ValidationErrors = struct {
    errors: std.ArrayListUnmanaged(FieldError),
    allocator: std.mem.Allocator,
    
    pub fn init(allocator: std.mem.Allocator) ValidationErrors {
        return ValidationErrors{
            .errors = std.ArrayListUnmanaged(FieldError){},
            .allocator = allocator,
        };
    }
    
    /// Add a validation error
    pub fn add(self: *ValidationErrors, field: []const u8, message: []const u8, code: []const u8) !void {
        try self.errors.append(self.allocator, FieldError{
            .field = field,
            .message = message,
            .code = code,
        });
    }
    
    /// Check if there are any errors
    pub fn isEmpty(self: *const ValidationErrors) bool {
        return self.errors.items.len == 0;
    }
    
    /// Get all errors
    pub fn getAll(self: *const ValidationErrors) []const FieldError {
        return self.errors.items;
    }
    
    /// Convert errors to JSON response
    pub fn toJson(self: *const ValidationErrors) ![]const u8 {
        var json = std.ArrayListUnmanaged(u8){};
        const writer = json.writer(self.allocator);
        
        try writer.print("{{\"errors\":[", .{});
        for (self.errors.items, 0..) |err, i| {
            if (i > 0) try writer.print(",", .{});
            try writer.print(
                "{{\"field\":\"{s}\",\"message\":\"{s}\",\"code\":\"{s}\"}}",
                .{ err.field, err.message, err.code },
            );
        }
        try writer.print("]}}", .{});
        
        return json.toOwnedSlice(self.allocator);
    }
    
    pub fn deinit(self: *ValidationErrors) void {
        self.errors.deinit(self.allocator);
    }
};

/// Validation rule function type
pub const ValidationRule = *const fn ([]const u8, std.mem.Allocator) ?[]const u8;

/// Field validator with rules
pub const FieldValidator = struct {
    field_name: []const u8,
    value: []const u8,
    rules: std.ArrayListUnmanaged(ValidationRule),
    allocator: std.mem.Allocator,
    
    pub fn init(allocator: std.mem.Allocator, field_name: []const u8, value: []const u8) FieldValidator {
        return FieldValidator{
            .field_name = field_name,
            .value = value,
            .rules = std.ArrayListUnmanaged(ValidationRule){},
            .allocator = allocator,
        };
    }
    
    /// Add a validation rule
    pub fn rule(self: *FieldValidator, rule_fn: ValidationRule) !void {
        try self.rules.append(self.allocator, rule_fn);
    }
    
    /// Validate the field against all rules
    pub fn validate(self: *const FieldValidator) ?[]const u8 {
        for (self.rules.items) |rule_fn| {
            if (rule_fn(self.value, self.allocator)) |error_msg| {
                return error_msg;
            }
        }
        return null;
    }
    
    pub fn deinit(self: *FieldValidator) void {
        self.rules.deinit(self.allocator);
    }
};

/// Validation schema for request validation
pub const ValidationSchema = struct {
    validators: std.ArrayListUnmanaged(FieldValidator),
    allocator: std.mem.Allocator,
    
    pub fn init(allocator: std.mem.Allocator) ValidationSchema {
        return ValidationSchema{
            .validators = std.ArrayListUnmanaged(FieldValidator){},
            .allocator = allocator,
        };
    }
    
    /// Add a field validator
    pub fn field(self: *ValidationSchema, field_name: []const u8, value: []const u8) !*FieldValidator {
        const validator = FieldValidator.init(self.allocator, field_name, value);
        try self.validators.append(self.allocator, validator);
        return &self.validators.items[self.validators.items.len - 1];
    }
    
    /// Validate all fields
    pub fn validate(self: *const ValidationSchema) !ValidationErrors {
        var errors = ValidationErrors.init(self.allocator);
        
        for (self.validators.items) |*validator| {
            if (validator.validate()) |error_msg| {
                try errors.add(validator.field_name, error_msg, "validation_failed");
            }
        }
        
        return errors;
    }
    
    pub fn deinit(self: *ValidationSchema) void {
        for (self.validators.items) |*validator| {
            validator.deinit();
        }
        self.validators.deinit(self.allocator);
    }
};

/// Common validation rules

/// Required field validation
pub fn required(value: []const u8, allocator: std.mem.Allocator) ?[]const u8 {
    _ = allocator;
    if (value.len == 0) {
        return "Field is required";
    }
    return null;
}

/// Minimum length validation (8 characters)
pub fn minLength8(value: []const u8, allocator: std.mem.Allocator) ?[]const u8 {
    _ = allocator;
    if (value.len < 8) {
        return "Field must be at least 8 characters";
    }
    return null;
}

/// Maximum length validation (100 characters)
pub fn maxLength100(value: []const u8, allocator: std.mem.Allocator) ?[]const u8 {
    _ = allocator;
    if (value.len > 100) {
        return "Field must be at most 100 characters";
    }
    return null;
}

/// Minimum length validation with parameter
/// For custom lengths, users should create their own validation functions
pub fn minLength(min_val: usize) ValidationRule {
    // Since we can't capture runtime values in function pointers easily,
    // we provide predefined validators and users can create custom ones
    _ = min_val;
    return &minLength8;
}

/// Maximum length validation with parameter  
pub fn maxLength(max_val: usize) ValidationRule {
    _ = max_val;
    return &maxLength100;
}

/// Email validation (simple)
pub fn email(value: []const u8, allocator: std.mem.Allocator) ?[]const u8 {
    _ = allocator;
    if (value.len == 0) return null; // Empty is handled by required()
    if (std.mem.indexOf(u8, value, "@") == null) {
        return "Invalid email format";
    }
    return null;
}

/// Integer validation
pub fn isInt(value: []const u8, allocator: std.mem.Allocator) ?[]const u8 {
    _ = allocator;
    if (value.len == 0) return null;
    _ = std.fmt.parseInt(i64, value, 10) catch return "Field must be an integer";
    return null;
}

/// Helper function to validate request body
pub fn validateRequest(req: *Request, schema: *ValidationSchema) !ValidationErrors {
    // Get form data or JSON body
    const form_data = try req.formBody();
    defer form_data.deinit();
    
    // Run validation
    return try schema.validate();
}

// Tests
test "ValidationErrors add and isEmpty" {
    var errors = ValidationErrors.init(std.testing.allocator);
    defer errors.deinit();
    
    try std.testing.expect(errors.isEmpty());
    
    try errors.add("name", "Name is required", "required");
    try std.testing.expect(!errors.isEmpty());
    try std.testing.expectEqual(errors.errors.items.len, 1);
}

test "FieldValidator required rule" {
    var validator = FieldValidator.init(std.testing.allocator, "name", "");
    defer validator.deinit();
    
    try validator.rule(&required);
    
    const err = validator.validate();
    try std.testing.expect(err != null);
}

test "FieldValidator minLength rule" {
    var validator = FieldValidator.init(std.testing.allocator, "password", "123");
    defer validator.deinit();
    
    try validator.rule(&minLength8);
    
    const err = validator.validate();
    try std.testing.expect(err != null);
}

test "ValidationSchema validate" {
    var schema = ValidationSchema.init(std.testing.allocator);
    defer schema.deinit();
    
    var name_validator = try schema.field("name", "");
    try name_validator.rule(&required);
    
    var errors = try schema.validate();
    defer errors.deinit();
    
    try std.testing.expect(!errors.isEmpty());
}

