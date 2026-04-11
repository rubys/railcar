# Generates the Python ApplicationRecord base class (models/base.py).
#
# This is the Python equivalent of src/runtime/application_record.cr.
# It provides ORM methods (save, find, all, where, reload, destroy),
# validation framework with error collection, and association support.
# Generated model classes inherit from this and declare their structure.

module Railcar
  class PythonModelRuntime
    def self.generate : String
      <<-'PYTHON'
from datetime import datetime


class ValidationErrors:
    """Rails-compatible error collection."""
    def __init__(self):
        self._errors = {}  # field → [messages]

    def add(self, field, message):
        self._errors.setdefault(field, []).append(message)

    def __bool__(self):
        return bool(self._errors)

    def __len__(self):
        return sum(len(v) for v in self._errors.values())

    def __iter__(self):
        for field, messages in self._errors.items():
            for msg in messages:
                yield ValidationError(field, msg)

    def __getitem__(self, field):
        return self._errors.get(field, [])

    def full_messages(self):
        result = []
        for field, messages in self._errors.items():
            for msg in messages:
                result.append(f"{field.replace('_', ' ').capitalize()} {msg}")
        return result


class ValidationError:
    """Single validation error with field and message."""
    def __init__(self, field, message):
        self.field = field
        self.message = message

    def full_message(self):
        return f"{self.field.replace('_', ' ').capitalize()} {self.message}"

    def __str__(self):
        return self.full_message()


class ApplicationRecord:
    """Base class for all models. Mirrors ActiveRecord for the blog demo."""
    TABLE = ''
    COLUMNS = []
    VALIDATIONS = []
    ASSOCIATIONS = []

    def __init__(self, **kwargs):
        self.id = kwargs.get('id')
        for col in self.COLUMNS:
            setattr(self, col, kwargs.get(col, self._default_for(col)))
        self._errors = ValidationErrors()

    def errors(self):
        return self._errors

    def _default_for(self, col):
        if col.endswith('_id'):
            return None
        if col in ('created_at', 'updated_at'):
            return None
        return ''

    # --- Finders ---

    @classmethod
    def from_row(cls, row):
        if row is None:
            return None
        return cls(**dict(row))

    @classmethod
    def find(cls, id):
        from models import get_db
        db = get_db()
        row = db.execute(f'SELECT * FROM {cls.TABLE} WHERE id = ?', (id,)).fetchone()
        db.close()
        if row is None:
            raise ValueError(f'{cls.__name__} not found: {id}')
        return cls.from_row(row)

    @classmethod
    def all(cls, order_by='id'):
        from models import get_db
        db = get_db()
        rows = db.execute(f'SELECT * FROM {cls.TABLE} ORDER BY {order_by}').fetchall()
        db.close()
        return [cls.from_row(r) for r in rows]

    @classmethod
    def where(cls, **conditions):
        from models import get_db
        db = get_db()
        clauses = ' AND '.join(f'{k} = ?' for k in conditions)
        rows = db.execute(f'SELECT * FROM {cls.TABLE} WHERE {clauses}',
                          tuple(conditions.values())).fetchall()
        db.close()
        return [cls.from_row(r) for r in rows]

    @classmethod
    def count(cls):
        return len(cls.all())

    @classmethod
    def last(cls):
        records = cls.all()
        return records[-1] if records else None

    @classmethod
    def _create(cls, **kwargs):
        obj = cls(**kwargs)
        obj.save()
        return obj

    # --- Persistence ---

    def reload(self):
        from models import get_db
        db = get_db()
        row = db.execute(f'SELECT * FROM {self.TABLE} WHERE id = ?',
                         (self.id,)).fetchone()
        db.close()
        if row:
            for key in dict(row):
                setattr(self, key, dict(row)[key])
        return self

    def save(self):
        self._errors = ValidationErrors()
        if not self._run_validations():
            return False
        from models import get_db
        db = get_db()
        now = datetime.now().isoformat()
        cols = [c for c in self.COLUMNS if c not in ('created_at', 'updated_at')]
        if self.id is None:
            if 'created_at' in self.COLUMNS:
                self.created_at = now
                self.updated_at = now
            all_cols = cols + [c for c in ('created_at', 'updated_at') if c in self.COLUMNS]
            col_str = ', '.join(all_cols)
            placeholders = ', '.join('?' for _ in all_cols)
            values = tuple(getattr(self, c) for c in all_cols)
            cursor = db.execute(
                f'INSERT INTO {self.TABLE} ({col_str}) VALUES ({placeholders})', values)
            self.id = cursor.lastrowid
        else:
            if 'updated_at' in self.COLUMNS:
                self.updated_at = now
            update_cols = [c for c in cols if c != 'created_at']
            if 'updated_at' in self.COLUMNS:
                update_cols.append('updated_at')
            sets = ', '.join(f'{c} = ?' for c in update_cols)
            values = tuple(getattr(self, c) for c in update_cols) + (self.id,)
            db.execute(f'UPDATE {self.TABLE} SET {sets} WHERE id = ?', values)
        db.commit()
        db.close()
        return True

    def destroy(self):
        # Cascade dependent: :destroy associations
        for assoc in self.ASSOCIATIONS:
            if assoc.get('kind') == 'has_many' and assoc.get('dependent') == 'destroy':
                for item in getattr(self, assoc['name'])():
                    item.destroy()
        from models import get_db
        db = get_db()
        db.execute(f'DELETE FROM {self.TABLE} WHERE id = ?', (self.id,))
        db.commit()
        db.close()

    # --- Validations ---

    def _run_validations(self):
        for v in self.VALIDATIONS:
            field = v['field']
            value = getattr(self, field, None)
            if v['kind'] == 'presence':
                if not value:
                    self._errors.add(field, "can't be blank")
            elif v['kind'] == 'length':
                if 'minimum' in v and value is not None and len(str(value)) < v['minimum']:
                    self._errors.add(field, f"is too short (minimum is {v['minimum']} characters)")
        # belongs_to FK validation
        for assoc in self.ASSOCIATIONS:
            if assoc.get('kind') == 'belongs_to':
                fk = assoc['name'] + '_id'
                fk_val = getattr(self, fk, None)
                if fk_val is not None:
                    try:
                        import importlib
                        mod = importlib.import_module('models.' + assoc['module'])
                        model_cls = getattr(mod, assoc['class_name'])
                        model_cls.find(fk_val)
                    except (ValueError, Exception):
                        self._errors.add(fk, 'is invalid')
        return not self._errors
PYTHON
    end
  end
end
