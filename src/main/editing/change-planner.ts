import { isDeepStrictEqual } from 'node:util'

export type FieldSnapshot = Readonly<Record<string, unknown>>

export interface ParameterizedSqlPlan {
  text: string
  values: unknown[]
}

export interface PostgresRowTarget {
  schema: string
  table: string
  primaryKey: FieldSnapshot
  original: FieldSnapshot
}

export interface PostgresUpdateInput extends PostgresRowTarget {
  current: FieldSnapshot
}

export interface MongoUpdateInput {
  original: FieldSnapshot
  current: FieldSnapshot
}

export interface MongoUpdatePlan {
  filter: Record<string, unknown>
  update: {
    $set?: Record<string, unknown>
    $unset?: Record<string, ''>
  }
}

type FieldEntry = readonly [name: string, value: unknown]

interface MongoFieldChange {
  field: string
  kind: 'set' | 'unset'
  currentValue?: unknown
}

const DANGEROUS_PROPERTY_NAMES = new Set(['__proto__', 'constructor', 'prototype'])

function defineDataProperty<T>(target: Record<string, T>, key: string, value: T): void {
  Object.defineProperty(target, key, {
    configurable: true,
    enumerable: true,
    writable: true,
    value
  })
}

function assertBindableValue(value: unknown, label: string): void {
  if (value === undefined) {
    throw new Error(`${label} cannot be undefined; use null for a database NULL value.`)
  }
  if (typeof value === 'function' || typeof value === 'symbol') {
    throw new Error(`${label} is not a supported database value.`)
  }
}

function assertFieldName(field: string, label: string, mongoPath: boolean): void {
  if (field.length === 0 || field.includes('\0')) {
    throw new Error(`${label} contains an invalid field name.`)
  }
  if (DANGEROUS_PROPERTY_NAMES.has(field)) {
    throw new Error(`${label} contains the dangerous key ${JSON.stringify(field)}.`)
  }
  if (mongoPath && (field.includes('$') || field.includes('.'))) {
    throw new Error(`${label} contains an unsafe MongoDB update path.`)
  }
}

function dataEntries(
  value: FieldSnapshot,
  label: string,
  mongoPath = false
): FieldEntry[] {
  if (value === null || typeof value !== 'object' || Array.isArray(value)) {
    throw new Error(`${label} must be a plain record.`)
  }
  const prototype = Object.getPrototypeOf(value)
  if (prototype !== Object.prototype && prototype !== null) {
    throw new Error(`${label} must be a plain record.`)
  }

  const entries: FieldEntry[] = []
  for (const key of Reflect.ownKeys(value)) {
    if (typeof key !== 'string') {
      throw new Error(`${label} cannot contain symbol keys.`)
    }
    const descriptor = Object.getOwnPropertyDescriptor(value, key)
    if (!descriptor?.enumerable || !('value' in descriptor)) {
      throw new Error(`${label} must contain only enumerable data properties.`)
    }
    assertFieldName(key, label, mongoPath)
    assertBindableValue(descriptor.value, `${label}.${key}`)
    entries.push([key, descriptor.value])
  }
  return entries
}

function entryMap(entries: FieldEntry[]): Map<string, unknown> {
  return new Map(entries)
}

export function quotePostgresIdentifier(identifier: string): string {
  if (typeof identifier !== 'string' || identifier.length === 0 || identifier.includes('\0')) {
    throw new Error('PostgreSQL identifiers must be non-empty strings without null bytes.')
  }
  return `"${identifier.replaceAll('"', '""')}"`
}

function postgresTarget(input: PostgresRowTarget): {
  qualifiedTable: string
  primaryKey: FieldEntry[]
  original: FieldEntry[]
} {
  const qualifiedTable = `${quotePostgresIdentifier(input.schema)}.${quotePostgresIdentifier(input.table)}`
  const primaryKey = dataEntries(input.primaryKey, 'PostgreSQL primary key')
  const original = dataEntries(input.original, 'PostgreSQL original patch')

  if (primaryKey.length === 0) {
    throw new Error('A PostgreSQL single-row change requires at least one primary-key column.')
  }
  if (original.length === 0) {
    throw new Error('A PostgreSQL single-row change requires original values for concurrency checks.')
  }

  const primaryKeyValues = entryMap(primaryKey)
  for (const [column, value] of primaryKey) {
    if (value === null) {
      throw new Error(`PostgreSQL primary-key column ${JSON.stringify(column)} cannot be null.`)
    }
  }
  for (const [column, value] of original) {
    if (primaryKeyValues.has(column) && !isDeepStrictEqual(primaryKeyValues.get(column), value)) {
      throw new Error(`PostgreSQL original value for primary-key column ${JSON.stringify(column)} is inconsistent.`)
    }
  }

  return { qualifiedTable, primaryKey, original }
}

function appendPostgresWhere(
  values: unknown[],
  primaryKey: FieldEntry[],
  original: FieldEntry[]
): string {
  const conditions: string[] = []
  const primaryKeyColumns = new Set(primaryKey.map(([column]) => column))

  for (const [column, value] of primaryKey) {
    values.push(value)
    conditions.push(`${quotePostgresIdentifier(column)} IS NOT DISTINCT FROM $${values.length}`)
  }
  for (const [column, value] of original) {
    if (primaryKeyColumns.has(column)) continue
    values.push(value)
    conditions.push(`${quotePostgresIdentifier(column)} IS NOT DISTINCT FROM $${values.length}`)
  }

  return conditions.join('\n  AND ')
}

/**
 * Plans one optimistic PostgreSQL row update. `original` and `current` contain
 * the same inspected columns; only values that actually changed are assigned.
 */
export function planPostgresUpdate(input: PostgresUpdateInput): ParameterizedSqlPlan {
  const target = postgresTarget(input)
  const current = dataEntries(input.current, 'PostgreSQL current patch')
  const originalValues = entryMap(target.original)

  if (
    current.length !== target.original.length ||
    current.some(([column]) => !originalValues.has(column))
  ) {
    throw new Error('PostgreSQL original and current patches must contain the same columns.')
  }

  const primaryKeyColumns = new Set(target.primaryKey.map(([column]) => column))
  const changed = current.filter(
    ([column, value]) => !isDeepStrictEqual(originalValues.get(column), value)
  )
  if (changed.length === 0) {
    throw new Error('A PostgreSQL update patch must contain at least one changed value.')
  }
  const changedPrimaryKey = changed.find(([column]) => primaryKeyColumns.has(column))
  if (changedPrimaryKey) {
    throw new Error(`PostgreSQL primary-key column ${JSON.stringify(changedPrimaryKey[0])} cannot be edited.`)
  }

  const values: unknown[] = []
  const assignments = changed.map(([column, value]) => {
    values.push(value)
    return `${quotePostgresIdentifier(column)} = $${values.length}`
  })
  const where = appendPostgresWhere(values, target.primaryKey, target.original)

  return {
    text: [
      `UPDATE ${target.qualifiedTable}`,
      `SET ${assignments.join(',\n    ')}`,
      `WHERE ${where}`,
      'RETURNING *;'
    ].join('\n'),
    values
  }
}

/** Plans one optimistic PostgreSQL row delete without executing it. */
export function planPostgresDelete(input: PostgresRowTarget): ParameterizedSqlPlan {
  const target = postgresTarget(input)
  const values: unknown[] = []
  const where = appendPostgresWhere(values, target.primaryKey, target.original)

  return {
    text: [
      `DELETE FROM ${target.qualifiedTable}`,
      `WHERE ${where}`,
      'RETURNING *;'
    ].join('\n'),
    values
  }
}

function mongoChanges(original: FieldEntry[], current: FieldEntry[]): MongoFieldChange[] {
  const originalValues = entryMap(original)
  const currentValues = entryMap(current)
  const changes: MongoFieldChange[] = []

  for (const [field, originalValue] of original) {
    if (field === '_id') continue
    if (!currentValues.has(field)) {
      changes.push({ field, kind: 'unset' })
    } else if (!isDeepStrictEqual(originalValue, currentValues.get(field))) {
      changes.push({ field, kind: 'set', currentValue: currentValues.get(field) })
    }
  }

  for (const [field, currentValue] of current) {
    if (field !== '_id' && !originalValues.has(field)) {
      changes.push({ field, kind: 'set', currentValue })
    }
  }

  return changes
}

function mongoOriginalCondition(value: unknown): Record<string, unknown> {
  return value === null
    ? { $eq: null, $exists: true }
    : { $eq: value }
}

/**
 * Plans a top-level, single-document MongoDB update. The filter compares every
 * original field with its original value — the same whole-document optimistic
 * granularity as deletes and PostgreSQL full-row changes. Fields added in
 * `current` must still be absent, which prevents silently overwriting a
 * concurrent insert.
 */
export function planMongoUpdate(input: MongoUpdateInput): MongoUpdatePlan {
  const original = dataEntries(input.original, 'MongoDB original document', true)
  const current = dataEntries(input.current, 'MongoDB current document', true)
  const originalValues = entryMap(original)
  const currentValues = entryMap(current)

  if (!originalValues.has('_id') || !currentValues.has('_id')) {
    throw new Error('A MongoDB single-document update requires _id in both documents.')
  }
  if (!isDeepStrictEqual(originalValues.get('_id'), currentValues.get('_id'))) {
    throw new Error('MongoDB _id cannot be edited.')
  }

  const changes = mongoChanges(original, current)
  if (changes.length === 0) {
    throw new Error('A MongoDB update must contain at least one changed or removed field.')
  }

  const filter = Object.create(null) as Record<string, unknown>
  defineDataProperty(filter, '_id', { $eq: originalValues.get('_id') })

  for (const [field, originalValue] of original) {
    if (field === '_id') continue
    defineDataProperty(filter, field, mongoOriginalCondition(originalValue))
  }
  for (const [field] of current) {
    if (field !== '_id' && !originalValues.has(field)) {
      defineDataProperty(filter, field, { $exists: false })
    }
  }

  const set = Object.create(null) as Record<string, unknown>
  const unset = Object.create(null) as Record<string, ''>
  for (const change of changes) {
    if (change.kind === 'set') {
      defineDataProperty(set, change.field, change.currentValue)
    } else {
      defineDataProperty(unset, change.field, '')
    }
  }

  const update: MongoUpdatePlan['update'] = {}
  if (Object.keys(set).length > 0) update.$set = set
  if (Object.keys(unset).length > 0) update.$unset = unset
  return { filter, update }
}
