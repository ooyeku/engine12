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

/// Parameterized validation rule data
pub const ParameterizedRule = union(enum) {
    min_length: usize,
    max_length: usize,
    one_of: []const []const u8,
    range: struct { min: i64, max: i64 },
};

/// Field validator with rules
pub const FieldValidator = struct {
    field_name: []const u8,
    value: []const u8,
    rules: std.ArrayListUnmanaged(ValidationRule),
    param_rules: std.ArrayListUnmanaged(ParameterizedRule),
    allocator: std.mem.Allocator,
    
    pub fn init(allocator: std.mem.Allocator, field_name: []const u8, value: []const u8) FieldValidator {
        return FieldValidator{
            .field_name = field_name,
            .value = value,
            .rules = std.ArrayListUnmanaged(ValidationRule){},
            .param_rules = std.ArrayListUnmanaged(ParameterizedRule){},
            .allocator = allocator,
        };
    }
    
    /// Add a validation rule
    pub fn rule(self: *FieldValidator, rule_fn: ValidationRule) !void {
        try self.rules.append(self.allocator, rule_fn);
    }
    
    /// Add a minLength validation rule with parameter
    pub fn minLength(self: *FieldValidator, min_val: usize) !void {
        try self.param_rules.append(self.allocator, .{ .min_length = min_val });
    }
    
    /// Add a maxLength validation rule with parameter
    pub fn maxLength(self: *FieldValidator, max_val: usize) !void {
        try self.param_rules.append(self.allocator, .{ .max_length = max_val });
    }
    
    /// Add a oneOf validation rule
    pub fn oneOf(self: *FieldValidator, allowed: []const []const u8) !void {
        try self.param_rules.append(self.allocator, .{ .one_of = allowed });
    }
    
    /// Add a range validation rule for numeric values
    pub fn range(self: *FieldValidator, min_val: i64, max_val: i64) !void {
        try self.param_rules.append(self.allocator, .{ .range = .{ .min = min_val, .max = max_val } });
    }
    
    /// Validate the field against all rules
    pub fn validate(self: *FieldValidator) ?[]const u8 {
        // Check standard rules first
        for (self.rules.items) |rule_fn| {
            if (rule_fn(self.value, self.allocator)) |error_msg| {
                return error_msg;
            }
        }
        
        // Check parameterized rules
        for (self.param_rules.items) |param_rule| {
            switch (param_rule) {
                .min_length => |min_val| {
                    if (self.value.len < min_val) {
                        var buf: [128]u8 = undefined;
                        const msg = std.fmt.bufPrint(&buf, "Field must be at least {d} characters", .{min_val}) catch return "Field too short";
                        const err_msg = self.allocator.dupe(u8, msg) catch return "Field too short";
                        return err_msg;
                    }
                },
                .max_length => |max_val| {
                    if (self.value.len > max_val) {
                        var buf: [128]u8 = undefined;
                        const msg = std.fmt.bufPrint(&buf, "Field must be at most {d} characters", .{max_val}) catch return "Field too long";
                        const err_msg = self.allocator.dupe(u8, msg) catch return "Field too long";
                        return err_msg;
                    }
                },
                .one_of => |allowed| {
                    var found = false;
                    for (allowed) |allowed_val| {
                        if (std.mem.eql(u8, self.value, allowed_val)) {
                            found = true;
                            break;
                        }
                    }
                    if (!found) {
                        const err_msg = self.allocator.dupe(u8, "Field value not in allowed list") catch return "Invalid value";
                        return err_msg;
                    }
                },
                .range => |r| {
                    const num = std.fmt.parseInt(i64, self.value, 10) catch {
                        const err_msg = self.allocator.dupe(u8, "Field must be a number") catch return "Invalid number";
                        return err_msg;
                    };
                    if (num < r.min or num > r.max) {
                        var buf: [128]u8 = undefined;
                        const msg = std.fmt.bufPrint(&buf, "Field must be between {d} and {d}", .{ r.min, r.max }) catch return "Value out of range";
                        const err_msg = self.allocator.dupe(u8, msg) catch return "Value out of range";
                        return err_msg;
                    }
                },
            }
        }
        
        return null;
    }
    
    pub fn deinit(self: *FieldValidator) void {
        self.rules.deinit(self.allocator);
        self.param_rules.deinit(self.allocator);
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

test "ValidationErrors multiple errors" {
    var errors = ValidationErrors.init(std.testing.allocator);
    defer errors.deinit();
    
    try errors.add("name", "Name is required", "required");
    try errors.add("email", "Invalid email format", "invalid_email");
    try errors.add("password", "Password too short", "min_length");
    
    try std.testing.expectEqual(errors.errors.items.len, 3);
    try std.testing.expect(!errors.isEmpty());
}

test "ValidationErrors getAll returns all errors" {
    var errors = ValidationErrors.init(std.testing.allocator);
    defer errors.deinit();
    
    try errors.add("field1", "Error 1", "code1");
    try errors.add("field2", "Error 2", "code2");
    
    const all_errors = errors.getAll();
    try std.testing.expectEqual(all_errors.len, 2);
    try std.testing.expectEqualStrings(all_errors[0].field, "field1");
    try std.testing.expectEqualStrings(all_errors[1].field, "field2");
}

test "ValidationErrors toJson formats correctly" {
    var errors = ValidationErrors.init(std.testing.allocator);
    defer errors.deinit();
    
    try errors.add("name", "Name is required", "required");
    try errors.add("email", "Invalid email", "invalid");
    
    const json = try errors.toJson();
    defer std.testing.allocator.free(json);
    
    try std.testing.expect(std.mem.indexOf(u8, json, "name") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "email") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "required") != null);
}

test "ValidationErrors empty toJson" {
    var errors = ValidationErrors.init(std.testing.allocator);
    defer errors.deinit();
    
    const json = try errors.toJson();
    defer std.testing.allocator.free(json);
    
    try std.testing.expect(std.mem.indexOf(u8, json, "errors") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "[]") != null);
}

test "FieldValidator multiple rules" {
    var validator = FieldValidator.init(std.testing.allocator, "password", "123");
    defer validator.deinit();
    
    try validator.rule(&required);
    try validator.rule(&minLength8);
    
    const err = validator.validate();
    try std.testing.expect(err != null);
    // Should return first error (required passes, minLength fails)
}

test "FieldValidator all rules pass" {
    var validator = FieldValidator.init(std.testing.allocator, "password", "longpassword123");
    defer validator.deinit();
    
    try validator.rule(&required);
    try validator.rule(&minLength8);
    
    const err = validator.validate();
    try std.testing.expect(err == null);
}

test "FieldValidator empty value with required rule" {
    var validator = FieldValidator.init(std.testing.allocator, "name", "");
    defer validator.deinit();
    
    try validator.rule(&required);
    
    const err = validator.validate();
    try std.testing.expect(err != null);
    try std.testing.expectEqualStrings(err.?, "Field is required");
}

test "FieldValidator maxLength rule" {
    var long_value = std.ArrayList(u8).init(std.testing.allocator);
    defer long_value.deinit();
    try long_value.writer().print("{s}", .{"x"} ** 101);
    
    var validator = FieldValidator.init(std.testing.allocator, "description", long_value.items);
    defer validator.deinit();
    
    try validator.rule(&maxLength100);
    
    const err = validator.validate();
    try std.testing.expect(err != null);
}

test "FieldValidator maxLength rule passes" {
    var validator = FieldValidator.init(std.testing.allocator, "description", "short");
    defer validator.deinit();
    
    try validator.rule(&maxLength100);
    
    const err = validator.validate();
    try std.testing.expect(err == null);
}

test "FieldValidator email rule valid email" {
    var validator = FieldValidator.init(std.testing.allocator, "email", "test@example.com");
    defer validator.deinit();
    
    try validator.rule(&email);
    
    const err = validator.validate();
    try std.testing.expect(err == null);
}

test "FieldValidator email rule invalid email" {
    var validator = FieldValidator.init(std.testing.allocator, "email", "notanemail");
    defer validator.deinit();
    
    try validator.rule(&email);
    
    const err = validator.validate();
    try std.testing.expect(err != null);
    try std.testing.expectEqualStrings(err.?, "Invalid email format");
}

test "FieldValidator email rule empty email" {
    var validator = FieldValidator.init(std.testing.allocator, "email", "");
    defer validator.deinit();
    
    try validator.rule(&email);
    
    // Empty email should pass (handled by required rule)
    const err = validator.validate();
    try std.testing.expect(err == null);
}

test "FieldValidator isInt rule valid integer" {
    var validator = FieldValidator.init(std.testing.allocator, "age", "25");
    defer validator.deinit();
    
    try validator.rule(&isInt);
    
    const err = validator.validate();
    try std.testing.expect(err == null);
}

test "FieldValidator isInt rule invalid integer" {
    var validator = FieldValidator.init(std.testing.allocator, "age", "25.5");
    defer validator.deinit();
    
    try validator.rule(&isInt);
    
    const err = validator.validate();
    try std.testing.expect(err != null);
}

test "FieldValidator isInt rule negative integer" {
    var validator = FieldValidator.init(std.testing.allocator, "temperature", "-10");
    defer validator.deinit();
    
    try validator.rule(&isInt);
    
    const err = validator.validate();
    try std.testing.expect(err == null);
}

test "FieldValidator isInt rule empty value" {
    var validator = FieldValidator.init(std.testing.allocator, "age", "");
    defer validator.deinit();
    
    try validator.rule(&isInt);
    
    const err = validator.validate();
    try std.testing.expect(err == null);
}

test "ValidationSchema multiple fields" {
    var schema = ValidationSchema.init(std.testing.allocator);
    defer schema.deinit();
    
    var name_validator = try schema.field("name", "");
    try name_validator.rule(&required);
    
    var email_validator = try schema.field("email", "invalid");
    try email_validator.rule(&email);
    
    var errors = try schema.validate();
    defer errors.deinit();
    
    try std.testing.expect(!errors.isEmpty());
    try std.testing.expect(errors.errors.items.len >= 1);
}

test "ValidationSchema no errors" {
    var schema = ValidationSchema.init(std.testing.allocator);
    defer schema.deinit();
    
    var name_validator = try schema.field("name", "John Doe");
    try name_validator.rule(&required);
    
    var errors = try schema.validate();
    defer errors.deinit();
    
    try std.testing.expect(errors.isEmpty());
}

test "ValidationSchema empty schema" {
    var schema = ValidationSchema.init(std.testing.allocator);
    defer schema.deinit();
    
    var errors = try schema.validate();
    defer errors.deinit();
    
    try std.testing.expect(errors.isEmpty());
}

test "FieldValidator no rules" {
    var validator = FieldValidator.init(std.testing.allocator, "name", "value");
    defer validator.deinit();
    
    const err = validator.validate();
    try std.testing.expect(err == null);
}

test "FieldValidator boundary values minLength" {
    var validator = FieldValidator.init(std.testing.allocator, "password", "1234567");
    defer validator.deinit();
    
    try validator.rule(&minLength8);
    
    const err = validator.validate();
    try std.testing.expect(err != null);
    
    var validator2 = FieldValidator.init(std.testing.allocator, "password", "12345678");
    defer validator2.deinit();
    
    try validator2.rule(&minLength8);
    
    const err2 = validator2.validate();
    try std.testing.expect(err2 == null);
}

test "FieldValidator boundary values maxLength" {
    var validator = FieldValidator.init(std.testing.allocator, "description", "x" ** 100);
    defer validator.deinit();
    
    try validator.rule(&maxLength100);
    
    const err = validator.validate();
    try std.testing.expect(err == null);
    
    var validator2 = FieldValidator.init(std.testing.allocator, "description", "x" ** 101);
    defer validator2.deinit();
    
    try validator2.rule(&maxLength100);
    
    const err2 = validator2.validate();
    try std.testing.expect(err2 != null);
}

