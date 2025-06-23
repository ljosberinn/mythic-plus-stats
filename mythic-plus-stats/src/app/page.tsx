"use client";

import { ChangeEvent, useState } from "react";
import luaparse from "luaparse";

type SavedVariables = {
  runsById: {
    [mapId: number]: {
      [keyLevel: number]: {
        [state: string]: {
          [runId: number]: {
            [key: string]: any;
          };
        };
      };
    };
  };
};

export default function Home() {
  const [data, setData] = useState<SavedVariables | null>(null);

  async function onFileSelection(event: ChangeEvent<HTMLInputElement>) {
    if (!event.target.files || event.target.files.length === 0) {
      return;
    }

    const file = event.target.files[0];
    const savedVariables = await new Promise<string>((resolve, reject) => {
      const reader = new FileReader();

      reader.onloadend = (event: ProgressEvent<FileReader>) => {
        resolve(event.target?.result?.toString() || "");
      };

      reader.readAsText(file);
    });

    if (!savedVariables) {
      return;
    }

    if (!savedVariables.includes("MythicPlusStatsDB")) {
      return;
    }

    function parseSavedVariables(savedVariables: string): SavedVariables {
      const ast = luaparse.parse(`local ${savedVariables}`);

      return {
        runsById: ast.body[0].init[0].fields[0].value.fields.reduce(
          (acc, tableKey) => {
            acc[tableKey.key.value] = tableKey.value.fields.reduce(
              (acc, value) => {
                acc[value.key.value] = value.value.fields.reduce(
                  (acc, value) => {
                    const state = value.key.raw.replaceAll('"', "");

                    acc[state] = value.value.fields.map((value) => {
                      return value.value.fields.reduce((acc, value) => {
                        const key = value.key.raw.replaceAll('"', "");

                        if (key === "encounters") {
                          acc[key] = value.value.fields.map((value) => {
                            return value.value.fields.reduce((acc, value) => {
                              const key = value.key.raw.replaceAll('"', "");

                              acc[key] = value.value.value;

                              return acc;
                            }, {});
                          });
                        } else {
                          acc[key] = value.value.value;
                        }

                        return acc;
                      }, {});
                    });

                    return acc;
                  },
                  {}
                );

                return acc;
              },
              {}
            );

            return acc;
          },
          {}
        ),
      } satisfies SavedVariables;
    }

    setData(parseSavedVariables(savedVariables));
  }

  if (data) {
    return <code>{JSON.stringify(data, null, 2)}</code>;
  }

  return (
    <div className="grid grid-rows-[20px_1fr_20px] items-center justify-items-center min-h-screen p-8 pb-20 gap-16 sm:p-20 font-[family-name:var(--font-geist-sans)]">
      <main className="flex flex-col gap-[32px] row-start-2 items-center sm:items-start">
        <ol className="list-inside list-decimal text-sm/6 text-center sm:text-left font-[family-name:var(--font-geist-mono)]">
          <li className="mb-2 tracking-[-.01em]">
            Select your{" "}
            <code className="bg-black/[.05] dark:bg-white/[.06] px-1 py-0.5 rounded font-[family-name:var(--font-geist-mono)] font-semibold">
              World of
              Warcraft\_retail_\WTF\Account\ACCOUNT_NAME_OR_ID\SavedVariables\MythicPlusStats.lua
            </code>
            .
          </li>
        </ol>

        <div className="flex gap-4 items-center flex-col sm:flex-row">
          <input
            accept=".lua"
            hidden
            type="file"
            id="file-input"
            onChange={onFileSelection}
          />
          <label
            className="rounded-full border border-solid border-transparent transition-colors flex items-center justify-center bg-foreground text-background gap-2 hover:bg-[#383838] dark:hover:bg-[#ccc] font-medium text-sm sm:text-base h-10 sm:h-12 px-4 sm:px-5 sm:w-auto"
            htmlFor="file-input"
          >
            Select File
          </label>
        </div>
      </main>
    </div>
  );
}
