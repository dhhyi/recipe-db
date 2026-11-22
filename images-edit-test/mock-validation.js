import {
  GraphQLNonNull,
  GraphQLString,
  getNamedType,
  getOperationAST,
  getVariableValues,
  isAbstractType,
  isEnumType,
  isListType,
  isNonNullType,
  isObjectType,
  isScalarType,
  parse,
  validate,
  valueFromASTUntyped,
} from "graphql";

function fail(message) {
  throw new Error(`Invalid GraphQL mock: ${message}`);
}

function isRecord(value) {
  if (value === null || typeof value !== "object" || Array.isArray(value)) {
    return false;
  }
  const prototype = Object.getPrototypeOf(value);
  return prototype === Object.prototype || prototype === null;
}

function isJsonValue(value, seen = new Set()) {
  if (
    value === null ||
    typeof value === "string" ||
    typeof value === "boolean" ||
    (typeof value === "number" && Number.isFinite(value))
  ) {
    return true;
  }
  if (typeof value !== "object" || seen.has(value)) return false;
  seen.add(value);
  const valid = Array.isArray(value)
    ? value.every((item) => isJsonValue(item, seen))
    : isRecord(value) &&
      Object.values(value).every((item) => isJsonValue(item, seen));
  seen.delete(value);
  return valid;
}

function shouldInclude(node, variables) {
  for (const directive of node.directives ?? []) {
    if (directive.name.value !== "skip" && directive.name.value !== "include") {
      continue;
    }
    const argument = directive.arguments.find(
      (item) => item.name.value === "if",
    );
    const value = valueFromASTUntyped(argument.value, variables);
    if (
      (directive.name.value === "skip" && value === true) ||
      (directive.name.value === "include" && value === false)
    ) {
      return false;
    }
  }
  return true;
}

function typeApplies(schema, runtimeType, condition) {
  if (runtimeType === condition) return true;
  return isAbstractType(condition) && schema.isSubType(condition, runtimeType);
}

function collectFields(
  schema,
  runtimeType,
  selectionSet,
  variables,
  fragments,
  fields = new Map(),
  visited = new Set(),
) {
  for (const selection of selectionSet.selections) {
    if (!shouldInclude(selection, variables)) continue;

    if (selection.kind === "Field") {
      const key = selection.alias?.value ?? selection.name.value;
      const group = fields.get(key) ?? [];
      group.push(selection);
      fields.set(key, group);
      continue;
    }

    if (selection.kind === "InlineFragment") {
      const condition = selection.typeCondition
        ? schema.getType(selection.typeCondition.name.value)
        : runtimeType;
      if (condition && typeApplies(schema, runtimeType, condition)) {
        collectFields(
          schema,
          runtimeType,
          selection.selectionSet,
          variables,
          fragments,
          fields,
          visited,
        );
      }
      continue;
    }

    const name = selection.name.value;
    if (visited.has(name)) continue;
    visited.add(name);
    const fragment = fragments.get(name);
    const condition = schema.getType(fragment.typeCondition.name.value);
    if (condition && typeApplies(schema, runtimeType, condition)) {
      collectFields(
        schema,
        runtimeType,
        fragment.selectionSet,
        variables,
        fragments,
        fields,
        visited,
      );
    }
  }
  return fields;
}

function fieldDefinition(schema, parentType, name) {
  if (name === "__typename") return { type: new GraphQLNonNull(GraphQLString) };
  return parentType.getFields()[name];
}

function validateScalar(value, type, path) {
  switch (type.name) {
    case "String":
      if (typeof value !== "string") fail(`${path} must be a String`);
      return;
    case "Boolean":
      if (typeof value !== "boolean") fail(`${path} must be a Boolean`);
      return;
    case "Int":
      if (
        !Number.isInteger(value) ||
        value < -2147483648 ||
        value > 2147483647
      ) {
        fail(`${path} must be a 32-bit Int`);
      }
      return;
    case "Float":
      if (typeof value !== "number" || !Number.isFinite(value)) {
        fail(`${path} must be a finite Float`);
      }
      return;
    case "ID":
      if (typeof value !== "string") fail(`${path} must be a serialized ID`);
      return;
    default:
      if (!isJsonValue(value)) fail(`${path} must be a JSON value`);
  }
}

function validateObject(
  schema,
  runtimeType,
  value,
  selectionSet,
  variables,
  fragments,
  responsePath,
  displayPath,
) {
  if (!isRecord(value)) fail(`${displayPath} must be an object`);
  const fields = collectFields(
    schema,
    runtimeType,
    selectionSet,
    variables,
    fragments,
  );
  const actualKeys = Object.keys(value);
  const expectedKeys = [...fields.keys()];
  for (const key of expectedKeys) {
    if (!Object.hasOwn(value, key)) fail(`${displayPath}.${key} is missing`);
  }
  for (const key of actualKeys) {
    if (!fields.has(key)) fail(`${displayPath}.${key} was not selected`);
  }

  for (const [responseKey, nodes] of fields) {
    const name = nodes[0].name.value;
    const definition = fieldDefinition(schema, runtimeType, name);
    const fieldPath = `${displayPath}.${responseKey}`;
    if (!definition) fail(`no schema field for ${fieldPath}`);
    if (name === "__typename" && value[responseKey] !== runtimeType.name) {
      fail(`${fieldPath} must be ${runtimeType.name}`);
    }
    const selections = nodes.flatMap(
      (node) => node.selectionSet?.selections ?? [],
    );
    const fieldSelection = selections.length > 0 ? { selections } : undefined;
    validateOutput(
      schema,
      value[responseKey],
      definition.type,
      fieldSelection,
      variables,
      fragments,
      [...responsePath, responseKey],
      fieldPath,
    );
  }
}

function validateOutput(
  schema,
  value,
  type,
  selectionSet,
  variables,
  fragments,
  responsePath,
  displayPath,
) {
  if (value === null) {
    if (isNonNullType(type)) {
      fail(`${displayPath} cannot be null`);
    }
    return;
  }
  if (isNonNullType(type)) {
    return validateOutput(
      schema,
      value,
      type.ofType,
      selectionSet,
      variables,
      fragments,
      responsePath,
      displayPath,
    );
  }
  if (isListType(type)) {
    if (!Array.isArray(value)) fail(`${displayPath} must be a list`);
    value.forEach((item, index) =>
      validateOutput(
        schema,
        item,
        type.ofType,
        selectionSet,
        variables,
        fragments,
        [...responsePath, index],
        `${displayPath}[${index}]`,
      ),
    );
    return;
  }

  const namedType = getNamedType(type);
  if (isScalarType(namedType)) {
    if (selectionSet) fail(`${displayPath} cannot have selected subfields`);
    validateScalar(value, namedType, displayPath);
    return;
  }
  if (isEnumType(namedType)) {
    if (selectionSet) fail(`${displayPath} cannot have selected subfields`);
    if (
      typeof value !== "string" ||
      !namedType.getValues().some((item) => item.name === value)
    ) {
      fail(`${displayPath} must be a ${namedType.name} value`);
    }
    return;
  }
  if (!selectionSet) fail(`${displayPath} requires selected subfields`);

  if (isObjectType(namedType)) {
    validateObject(
      schema,
      namedType,
      value,
      selectionSet,
      variables,
      fragments,
      responsePath,
      displayPath,
    );
    return;
  }
  if (isAbstractType(namedType)) {
    fail(
      `${displayPath} has unsupported abstract output type ${namedType.name}`,
    );
  }
  fail(`${displayPath} has an unsupported output type`);
}

function validateErrors(errors) {
  if (!Array.isArray(errors) || errors.length === 0) {
    fail("errors must be a non-empty array");
  }
  for (const error of errors) {
    if (!isRecord(error) || typeof error.message !== "string") {
      fail("each error must be an object with a message");
    }
    for (const key of Object.keys(error)) {
      if (!["message", "locations", "path", "extensions"].includes(key)) {
        fail(`error.${key} is not a GraphQL response property`);
      }
    }
    if (
      error.path !== undefined &&
      (!Array.isArray(error.path) ||
        !error.path.every(
          (part) =>
            typeof part === "string" || (Number.isInteger(part) && part >= 0),
        ))
    ) {
      fail("error paths must contain field names or non-negative indexes");
    }
    if (
      error.locations !== undefined &&
      (!Array.isArray(error.locations) ||
        !error.locations.every(
          (location) =>
            isRecord(location) &&
            Number.isInteger(location.line) &&
            location.line > 0 &&
            Number.isInteger(location.column) &&
            location.column > 0,
        ))
    ) {
      fail("error locations must contain positive line and column numbers");
    }
    if (
      error.extensions !== undefined &&
      (!isRecord(error.extensions) || !isJsonValue(error.extensions))
    ) {
      fail("error extensions must be a JSON object");
    }
  }
}

function validateMock(schema, mock) {
  if (!isRecord(mock)) fail("mock must be an object");
  if (Object.hasOwn(mock, "responses")) {
    if (Object.hasOwn(mock, "response")) {
      fail("mock must specify either response or responses, not both");
    }
    if (!Array.isArray(mock.responses) || mock.responses.length === 0) {
      fail("responses must be a non-empty array");
    }
    const { responses, ...request } = mock;
    for (const response of responses) {
      validateMock(schema, { ...request, response });
    }
    return true;
  }
  if (typeof mock.query !== "string") fail("query must be a string");
  if (!isRecord(mock.variables)) fail("variables must be an object");
  if (!isRecord(mock.response)) fail("response must be an object");
  for (const key of Object.keys(mock.response)) {
    if (!["data", "errors", "extensions"].includes(key)) {
      fail(`response.${key} is not a GraphQL response property`);
    }
  }

  let document;
  try {
    document = parse(mock.query);
  } catch (error) {
    fail(`query could not be parsed: ${error.message}`);
  }
  const validationErrors = validate(schema, document);
  if (validationErrors.length > 0) {
    fail(`query is not valid for the schema: ${validationErrors[0].message}`);
  }

  const operationName = mock.operationName;
  if (
    operationName !== undefined &&
    operationName !== null &&
    typeof operationName !== "string"
  ) {
    fail("operationName must be a string when provided");
  }
  const operation = getOperationAST(document, operationName ?? undefined);
  if (!operation) fail("operationName does not identify a single operation");

  const variableResult = getVariableValues(
    schema,
    operation.variableDefinitions ?? [],
    mock.variables,
  );
  if (variableResult.errors?.length) {
    fail(`variables are invalid: ${variableResult.errors[0].message}`);
  }
  const variables = variableResult.coerced;

  const response = mock.response;
  if (response.errors !== undefined) validateErrors(response.errors);
  if (
    response.extensions !== undefined &&
    (!isRecord(response.extensions) || !isJsonValue(response.extensions))
  ) {
    fail("extensions must be a JSON object");
  }
  if (!Object.hasOwn(response, "data")) {
    if (response.errors?.length) return true;
    fail("response must include data or non-empty errors");
  }
  if (response.data === null) {
    if (response.errors?.length) return true;
    fail("data cannot be null without errors");
  }
  if (!isRecord(response.data)) fail("data must be an object or null");

  const rootType =
    operation.operation === "query"
      ? schema.getQueryType()
      : operation.operation === "mutation"
        ? schema.getMutationType()
        : schema.getSubscriptionType();
  if (!rootType) fail(`schema has no ${operation.operation} root type`);
  const fragments = new Map(
    document.definitions
      .filter((definition) => definition.kind === "FragmentDefinition")
      .map((definition) => [definition.name.value, definition]),
  );
  validateObject(
    schema,
    rootType,
    response.data,
    operation.selectionSet,
    variables,
    fragments,
    [],
    "data",
  );
  return true;
}

function takeMockResponse(mock) {
  if (!Object.hasOwn(mock, "responses")) return mock.response;
  if (mock.responses.length === 0) {
    throw new Error(`GraphQL mock responses exhausted: ${mock.query}`);
  }
  return mock.responses.shift();
}

export { takeMockResponse, validateMock };
