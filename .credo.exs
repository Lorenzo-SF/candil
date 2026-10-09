%{
  configs: [
    %{
      name: "default",
      strict: false,

      # El codigo de salida lo decide ESTO, no `--strict`.
      #
      # `--strict` sube *todos* los checks a `:high`, incluidos los de
      # legibilidad como `NestedModules`, que dice «este modulo anidado podria
      # aliasearse arriba». No hay forma de que un alias este mal puesto, y un
      # gate que se cae por eso ensena a ignorar el rojo.
      #
      # Con `--strict` en la linea de comandos, esto NO se aplica — el flag
      # manda sobre la config. Por eso el CI usa `--strict` a proposito (mas
      # checks activos) pero los de legibilidad se bajan aqui, y el rc sale de
      # aqui.
      exit_status: 2,
      parse_timeout: 5_000,
      color: true,
      checks: [
        {Credo.Check.Consistency.ExceptionNames},
        {Credo.Check.Consistency.LineEndings},
        {Credo.Check.Consistency.ParameterPatternMatching},
        {Credo.Check.Consistency.SpaceAroundOperators},
        {Credo.Check.Consistency.SpaceInParentheses},
        {Credo.Check.Consistency.TabsOrSpaces},
        {Credo.Check.Design.AliasUsage, priority: :low},

        {Credo.Check.Design.TagTODO},
        {Credo.Check.Design.TagFIXME},
        {Credo.Check.Readability.AliasOrder},
        {Credo.Check.Readability.FunctionNames},
        {Credo.Check.Readability.LargeNumbers},
        {Credo.Check.Readability.MaxLineLength, max_length: 120},
        {Credo.Check.Readability.ModuleDoc},
        {Credo.Check.Readability.ModuleNames},

        # "Nested modules could be aliased" es legibilidad, no correccion: no
        # hay forma de que un alias este mal puesto, solo de que se podria
        # abreviar. Con `--strict` el gate lo subia a `:high` y caia con treinta
        # y tantos `[D]` sin senalar ningun problema real.
        {Credo.Check.Readability.NestedModules, priority: :low},
        {Credo.Check.Readability.ParenthesesInCondition},
        {Credo.Check.Readability.PredicateFunctionNames},
        {Credo.Check.Readability.RedundantBlankLines},
        {Credo.Check.Readability.StringSigils},
        {Credo.Check.Readability.TrailingBlankLine},
        {Credo.Check.Readability.TrailingWhiteSpace},
        {Credo.Check.Readability.UnnecessaryAliasExpansion},
        {Credo.Check.Readability.VariableNames},
        {Credo.Check.Refactor.CondStatements},
        {Credo.Check.Refactor.CyclomaticComplexity},
        {Credo.Check.Refactor.FunctionArity},
        {Credo.Check.Refactor.LongQuoteBlocks},
        {Credo.Check.Refactor.MatchInCondition},
        {Credo.Check.Refactor.MapInto},
        {Credo.Check.Refactor.NegatedConditionsInUnless},
        {Credo.Check.Refactor.NegatedConditionsWithElse},
        {Credo.Check.Refactor.Nesting, max_nesting: 3},
        {Credo.Check.Refactor.UnlessWithElse},
        {Credo.Check.Refactor.WithClauses},
        {Credo.Check.Warning.ApplicationConfigInModuleAttribute},
        {Credo.Check.Warning.BoolOperationOnSameValues},
        {Credo.Check.Warning.ExpensiveEmptyEnumCheck},
        {Credo.Check.Warning.IExPry},
        {Credo.Check.Warning.IoInspect},
        {Credo.Check.Warning.MissedMetadataKeyInLoggerConfig},
        {Credo.Check.Warning.OperationOnSameValues},
        {Credo.Check.Warning.OperationWithConstantResult},
        {Credo.Check.Warning.RaiseInsideRescue},
        {Credo.Check.Warning.UnsafeExec},
        {Credo.Check.Warning.UnsafeToAtom}
      ]
    }
  ]
}
