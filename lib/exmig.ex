defmodule Migrations do
  @moduledoc """

  Migrations module allows to define a sequence of upgrade/downgrade
  migrations, typically database alterations.

  It is important to preserve the order of ups and downs throughout the
  lifetime of the module.

  `use Migrations` accepts following options:

  * `prefix`: by default, prefix is assumed to be `__MODULE__`, but
    can be overriden with this option

  See documentation for `up` and `down` macros.

  ## Examples

    defmodule MyMigrations do
      use Migrations

      up "first migration" do
        # ...
      end
      down do
        # ...
      end
    end

    defmodule MyOtherMigrations do
      use Migrations, prefix: MyMigrations

      up "first migration" do
        # ...
      end
      down do
        # ...
      end
    end

  """

  defmodule Migration do
    defstruct id: nil, timestamp: nil
  end

  defmacro __using__(opts) do
    quote do
      import Migrations
      Module.register_attribute __MODULE__, :migrations, persist: true, accumulate: true
      Module.register_attribute __MODULE__, :migration_options, persist: true, accumulate: false
      @migration_options unquote(opts)
      @before_compile Migrations
      prefix = unquote(opts[:prefix]) || __MODULE__
      unless is_binary(prefix) do
        prefix = inspect(prefix)
      end
      @prefix prefix

      def __prefix__, do: @prefix
    end
  end

  defmacro __before_compile__(_) do
    quote do
      def upgrade(_, _), do: nil
      def downgrade(_, _), do: nil
    end
  end

  @doc """
  `up` macro defines an upgrade migration. It will always require
  a body and either a name, or both a name and target instance
  (such as Migrations.ETS or Migrations.PostgreSQL.EPgSQL)

  It will raise ArgumentError if a migration with the same name
  is already defined in the module.

  ## Examples

    up "first table" do
    end

    up "first table", conn do
    end

  """
  defmacro up(name, state \\ (quote do: _state), body) do
    quote do
      name = "#{@prefix}: #{unquote(name)}"
      @name name
      if Enum.member?(@migrations, name) do
        raise ArgumentError, message: "upgrade '#{name}' already exists"
      end
      def upgrade(@name, unquote(state)), unquote(body)
      @migrations name
      @current_migration nil
    end
  end

  @doc """
  `down` macro defines a downgrade migration. It will always require
  a body and either no arugments, or a name, or both a name and target instance
  (such as Migrations.ETS or Migrations.PostgreSQL.EPgSQL)

  It will raise ArgumentError if a migration with the same name
  is already defined in the module.

  Unlike in `up`, one can use `down` without a name, and it will use the latest
  defined `up` as a source of the migration name.

  ## Examples

    up "first table" do
    end
    down do
    end

    up "second table", conn do
    end
    down conn do
    end

    up "third table", conn do
    end
    down "third table", conn do
    end

  """
  defmacro down(body) do
    _down((quote do: _state), body)
  end
  defmacro down(state, body) do
    _down(state, body)
  end
  defp _down(state, body) when not is_binary(state) do
    quote do
      unless is_nil(@current_migration) do
        raise ArgumentError, message: "downgrade '#{@current_migration}' already exists"
      end
      @current_migration hd(@migrations)
      def downgrade(@current_migration, unquote(state)), unquote(body)
    end
  end
  defp _down(name, body) when is_binary(name) do
    quote do
      name = "#{@prefix}: #{unquote(name)}"
      @name name
      unless is_nil(@current_migration) do
        raise ArgumentError, message: "downgrade '#{@current_migration}' already exists"
      end
      @current_migration name
      def downgrade(@name, _state), unquote(body)
    end
  end

  defmacro down(name, state, body) do
    quote do
      name = "#{@prefix}: #{unquote(name)}"
      @name name
      unless is_nil(@current_migration) do
        raise ArgumentError, message: "downgrade '#{@current_migration}' already exists"
      end
      @current_migration name
      def downgrade(@name, unquote(state)), unquote(body)
    end
  end

  @doc """
  Returns all migrations in the module
  """
  def all(module) do
    for {:migrations, [id]} <- module.__info__(:attributes) do
      struct(Migration, id: id)
    end
  end

  alias Migrations.Implementation, as: I

  @type upgrade_result :: :up_to_date | {:upgrade, [Migration.t]} | {:downgrade, [Migration.t]}
  @doc """
  Migrates according to the module
  """
  @spec migrate(module, term) :: upgrade_result
  @spec migrate(module, term, term) :: upgrade_result
  def migrate(module, instance) do
    do_migrate(module, migration_path(module, instance))
  end
  @doc """
  Migrates according to the module, up or down to a specific
  version
  """
  def migrate(module, version, instance) do
    do_migrate(module, migration_path(module, version, instance))
  end

  defp do_migrate(_module, {_instance, :up_to_date}), do: :up_to_date
  defp do_migrate(module, {instance, {:upgrade, path} = migration}) do
    for m <- path do
      I.execute!(instance, module, :upgrade, [m.id, instance])
      I.add!(instance, m)
    end
    migration
  end
  defp do_migrate(module, {instance, {:downgrade, path} = migration}) do
    for m <- path do
      I.execute!(instance, module, :downgrade, [m.id, instance])
      I.remove!(instance, m)
    end
    migration
  end


  def migration_path(module, instance) do
    last_version = all(module) |> Enum.reverse |> List.first
    case last_version do
      nil -> :up_to_date
      %Migration{id: version} ->
        migration_path(module, version, instance)
    end
  end

  def migration_path(module, version, instance) do
    instance = I.init(instance)
    migrations = Enum.drop_while(Enum.reverse(all(module)), fn(x) -> x.id != version end) |>
                 Enum.reverse
    current_migrations = I.migrations(instance) |>
                         Enum.filter(fn(m) -> String.starts_with?(m.id, module.__prefix__ <> ": ") end) |>
                         Enum.sort(fn(x, y) -> x.timestamp > y.timestamp end) |>
                         Enum.map(fn(x) -> x.id end)
    result =
    case current_migrations do
      [^version|_] -> :up_to_date
      [] ->
        # full upgrade path
        path = migrations
        {:upgrade, path}
      [last_version|_] ->
        if Enum.member?(migrations, struct(Migration, id: last_version)) do
          path = Enum.drop_while(migrations, fn(%Migration{id: id}) -> id != last_version end)
          {:upgrade, tl(path)}
        else
          path = Enum.take_while(Enum.reverse(all(module)), fn(%Migration{id: id}) -> id != version end)
          {:downgrade, path}
        end
    end
    {instance, result}
  end

  @spec options(module) :: [{term, term}]
  def options(module) do
    module.__info__(:attributes)[:migration_options]
  end

end
