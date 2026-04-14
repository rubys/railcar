# Python runtime for railcar-generated apps.
# Hand-written Python (not transpiled from Crystal).
# Crystal base.cr is used only for program.semantic() type checking.

from datetime import datetime
import json
import base64

MODEL_REGISTRY = {}


def _turbo_stream_html(action, target, content=""):
    if content:
        return f'<turbo-stream action="{action}" target="{target}"><template>{content}</template></turbo-stream>'
    return f'<turbo-stream action="{action}" target="{target}"></turbo-stream>'


class ValidationErrors:
    def __init__(self):
        self._errors = {}

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

    def clear(self):
        self._errors.clear()


class ValidationError:
    def __init__(self, field, message):
        self.field = field
        self.message = message

    def full_message(self):
        return f"{self.field.replace('_', ' ').capitalize()} {self.message}"

    def __str__(self):
        return self.full_message()


class CollectionProxy:
    def __init__(self, owner, foreign_key, model_name):
        self.owner = owner
        self.foreign_key = foreign_key
        self.model_name = model_name

    def model_class(self):
        return MODEL_REGISTRY[self.model_name]

    def build(self, attrs=None, **kwargs):
        if attrs:
            kwargs.update(attrs)
        kwargs[self.foreign_key] = self.owner.id
        return self.model_class()(**kwargs)

    def create(self, **attrs):
        record = self.build(**attrs)
        record.save()
        return record

    def destroy_all(self):
        cls = self.model_class()
        ApplicationRecord.db.execute(
            f"DELETE FROM {cls.TABLE} WHERE {self.foreign_key} = ?",
            (self.owner.id,))
        ApplicationRecord.db.commit()

    def size(self):
        return len(self.all())

    def __len__(self):
        return self.size()

    def __iter__(self):
        return iter(self.all())

    def find(self, id):
        return self.model_class().find(id)

    def all(self):
        return self.model_class().where(**{self.foreign_key: self.owner.id})


class ApplicationRecord:
    db = None
    TABLE = ''
    COLUMNS = []

    def __init_subclass__(cls, **kwargs):
        super().__init_subclass__(**kwargs)
        MODEL_REGISTRY[cls.__name__] = cls

    # --- Callback registration (class-level) ---

    @classmethod
    def after_save(cls, callback):
        if '_after_save_callbacks' not in cls.__dict__:
            cls._after_save_callbacks = []
        cls._after_save_callbacks.append(callback)

    @classmethod
    def after_destroy(cls, callback):
        if '_after_destroy_callbacks' not in cls.__dict__:
            cls._after_destroy_callbacks = []
        cls._after_destroy_callbacks.append(callback)

    def _run_callbacks(self, name):
        callbacks = getattr(self.__class__, f'_{name}_callbacks', [])
        for cb in callbacks:
            cb(self)

    # --- Broadcasting ---

    _broadcaster = None  # Set to CableServer instance by app.py
    render_partial = None  # Set by app.py to the view's render_*_partial function

    def _broadcast(self, action, channel, target=None):
        if not ApplicationRecord._broadcaster:
            return
        if target is None:
            target = self._dom_id() if action in ('replace', 'remove') else self.__class__.TABLE
        if action == 'remove':
            html = ''
        elif self.__class__.render_partial:
            html = self.__class__.render_partial(self)
        else:
            html = self.to_html()
        stream = _turbo_stream_html(action, target, html)
        import asyncio
        try:
            asyncio.get_running_loop()
            asyncio.ensure_future(ApplicationRecord._broadcaster.broadcast(channel, stream))
        except RuntimeError:
            pass

    def broadcast_replace_to(self, channel, target=None):
        self._broadcast('replace', channel, target)

    def broadcast_append_to(self, channel, target=None):
        self._broadcast('append', channel, target)

    def broadcast_prepend_to(self, channel, target=None):
        self._broadcast('prepend', channel, target)

    def broadcast_remove_to(self, channel, target=None):
        self._broadcast('remove', channel, target)

    def _dom_id(self):
        name = self.__class__.__name__.lower()
        return f"{name}_{self.id}"

    def to_html(self):
        """Fallback HTML for broadcasts when no partial is available."""
        dom_id = self._dom_id()
        attrs = ' '.join(
            f'<span class="{k}">{getattr(self, k, "")}</span>'
            for k in self.__class__.COLUMNS
            if k not in ('created_at', 'updated_at')
        )
        return f'<div id="{dom_id}">{attrs}</div>'

    def __init__(self, attrs=None, **kwargs):
        if attrs:
            kwargs.update(attrs)
        self.id = kwargs.get('id')
        for col in self.__class__.COLUMNS:
            setattr(self, col, kwargs.get(col, self._default_for(col)))
        self._persisted = kwargs.get('_persisted', False)
        self._errors = ValidationErrors()

    def _default_for(self, col):
        if col.endswith('_id'):
            return None
        if col in ('created_at', 'updated_at'):
            return None
        return ''

    @property
    def errors(self):
        return self._errors

    @property
    def persisted(self):
        return self._persisted

    def new_record(self):
        return not self._persisted

    def valid(self):
        self._errors = ValidationErrors()
        self.run_validations()
        return not self._errors

    def update(self, attrs):
        for k, v in attrs.items():
            setattr(self, k, v)
        return self.save()

    def run_validations(self):
        pass

    def save(self):
        self._errors = ValidationErrors()
        self.run_validations()
        if self._errors:
            return False
        db = self.__class__.db
        now = datetime.now().isoformat(sep=' ', timespec='microseconds')
        cols = [c for c in self.__class__.COLUMNS if c not in ('created_at', 'updated_at')]
        if self.id is None:
            if 'created_at' in self.__class__.COLUMNS:
                self.created_at = now
                self.updated_at = now
            all_cols = cols + [c for c in ('created_at', 'updated_at') if c in self.__class__.COLUMNS]
            placeholders = ', '.join('?' for _ in all_cols)
            col_str = ', '.join(all_cols)
            values = tuple(getattr(self, c) for c in all_cols)
            cursor = db.execute(
                f"INSERT INTO {self.__class__.TABLE} ({col_str}) VALUES ({placeholders})", values)
            self.id = cursor.lastrowid
            self._persisted = True
        else:
            if 'updated_at' in self.__class__.COLUMNS:
                self.updated_at = now
            update_cols = [c for c in cols if c != 'created_at']
            if 'updated_at' in self.__class__.COLUMNS:
                update_cols.append('updated_at')
            sets = ', '.join(f'{c} = ?' for c in update_cols)
            values = tuple(getattr(self, c) for c in update_cols) + (self.id,)
            db.execute(
                f"UPDATE {self.__class__.TABLE} SET {sets} WHERE id = ?", values)
        db.commit()
        self._run_callbacks('after_save')
        return True

    def destroy(self):
        if not self._persisted:
            return False
        db = self.__class__.db
        db.execute(f"DELETE FROM {self.__class__.TABLE} WHERE id = ?", (self.id,))
        db.commit()
        self._persisted = False
        self._run_callbacks('after_destroy')
        return True

    def reload(self):
        fresh = self.__class__.find(self.id)
        for col in self.__class__.COLUMNS:
            setattr(self, col, getattr(fresh, col))
        return self

    @classmethod
    def find(cls, id):
        row = cls.db.execute(
            f"SELECT * FROM {cls.TABLE} WHERE id = ?", (id,)).fetchone()
        if row is None:
            raise ValueError(f"{cls.__name__} not found: {id}")
        return cls.from_row(row)

    @classmethod
    def all(cls, order_by='id'):
        rows = cls.db.execute(
            f"SELECT * FROM {cls.TABLE} ORDER BY {order_by}").fetchall()
        return [cls.from_row(r) for r in rows]

    @classmethod
    def where(cls, **conditions):
        clauses = ' AND '.join(f'{k} = ?' for k in conditions)
        rows = cls.db.execute(
            f"SELECT * FROM {cls.TABLE} WHERE {clauses}",
            tuple(conditions.values())).fetchall()
        return [cls.from_row(r) for r in rows]

    @classmethod
    def count(cls):
        result = cls.db.execute(
            f"SELECT COUNT(*) FROM {cls.TABLE}").fetchone()
        return result[0]

    @classmethod
    def last(cls):
        records = cls.all()
        return records[-1] if records else None

    @classmethod
    def create(cls, **kwargs):
        record = cls(**kwargs)
        record.save()
        return record

    @classmethod
    def from_row(cls, row):
        if row is None:
            return None
        data = dict(row)
        data['_persisted'] = True
        return cls(**data)
