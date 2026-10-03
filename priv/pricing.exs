# Precios por modelo, en USD por 1M tokens: {entrada, salida}.
#
# Estaban embebidos en el modulo, que hacia que cambiar un precio fuera
# cambiar codigo. El diseno (fase 5, 5.2) los saca aqui: los precios cambian
# cada mes y no son codigo.
#
# Los locales valen 0.0, y no por accident: un modelo que corre en tu GPU no
# cuesta nada por token. Lo que no es correcto es el precio del proveedor
# copiado aqui para un modelo local, y por eso los locales llevan 0.0.

%{
    "gpt-4o" => {2.50, 10.00},
    "gpt-4o-2024-08-06" => {2.50, 10.00},
    "gpt-4o-mini" => {0.15, 0.60},
    "gpt-4o-mini-2024-07-18" => {0.15, 0.60},
    "gpt-4-turbo" => {10.00, 30.00},
    "gpt-4-turbo-2024-04-09" => {10.00, 30.00},
    "gpt-4" => {30.00, 60.00},
    "gpt-3.5-turbo" => {0.50, 1.50},
    "o1-preview" => {15.00, 60.00},
    "o1-mini" => {3.00, 12.00},  # Anthropic
    "claude-3-5-sonnet-20241022" => {3.00, 15.00},
    "claude-3-5-sonnet-latest" => {3.00, 15.00},
    "claude-3-5-haiku-20241022" => {0.80, 4.00},
    "claude-3-5-haiku-latest" => {0.80, 4.00},
    "claude-3-opus-20240229" => {15.00, 75.00},
    "claude-3-sonnet-20240229" => {3.00, 15.00},
    "claude-3-haiku-20240307" => {0.25, 1.25},  # Local (free)
    "llama3" => {0.0, 0.0},
    "llama3.1" => {0.0, 0.0},
    "llama3.2" => {0.0, 0.0},
    "llama3.3" => {0.0, 0.0},
    "mistral" => {0.0, 0.0},
    "qwen2" => {0.0, 0.0},
    "gemma2" => {0.0, 0.0},
}
